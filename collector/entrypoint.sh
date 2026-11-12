#!/bin/sh
set -eu

ACCOUNTS_DIR="${ACCOUNTS_DIR:-/accounts}"
DATA_DIR="${DATA_DIR:-/data}"
SMTP_HOST="${SMTP_HOST:-stalwart}"
SMTP_PORT="${SMTP_PORT:-2525}"
DEFAULT_LOCAL_RECIPIENT="${DEFAULT_LOCAL_RECIPIENT:-}"
SMTP_BATCH_LIMIT="${SMTP_BATCH_LIMIT:-8}"
GLOBAL_FETCH_ALL_FIRST="${FETCH_ALL_ON_FIRST_RUN:-false}"

# Docker 在 bind mount 源目录不存在时会以 root:root 创建目录。
# Collector 镜像只在启动初期短暂以 root 修正挂载根目录所有权，
# 真正的 fetchmail 进程仍通过 su-exec 以 UID/GID 10001 运行。
mkdir -p "$DATA_DIR"
chown 10001:10001 "$DATA_DIR"
chmod 0750 "$DATA_DIR"

bool_value() {
    case "$1" in
        true|1|yes|on) printf '%s' true ;;
        false|0|no|off) printf '%s' false ;;
        *) return 1 ;;
    esac
}

escape_fetchmail() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

worker() {
    cfg="$1"
    . "$cfg"

    : "${ACCOUNT_NAME:?ACCOUNT_NAME missing in $cfg}"
    : "${IMAP_HOST:?IMAP_HOST missing in $cfg}"
    : "${IMAP_USER:?IMAP_USER missing in $cfg}"
    : "${IMAP_PASSWORD:?IMAP_PASSWORD missing in $cfg}"

    PROTOCOL="$(printf '%s' "${PROTOCOL:-IMAP}" | tr '[:lower:]' '[:upper:]')"
    IMAP_PORT="${IMAP_PORT:-993}"
    IMAP_FOLDER="${IMAP_FOLDER:-INBOX}"
    FETCH_MODE="${FETCH_MODE:-idle}"
    POLL_INTERVAL="${POLL_INTERVAL:-60}"
    # Fetchmail 要求服务器级选项（uidl）写在 user 之前，用户级选项（folder）写在 user 之后。
    case "$PROTOCOL" in
        IMAP)
            server_lines=""
            user_lines="    folder \"$(escape_fetchmail "$IMAP_FOLDER")\""
            ;;
        POP3)
            # 163/126 等网易邮箱的 IMAP 要求客户端发送 RFC 2971 ID，Fetchmail 不支持，
            # SELECT 会返回 “Unsafe Login”；POP3 不受该限制。POP3 没有文件夹也没有 IDLE，
            # 配合 keep 必须使用 uidl，避免每次轮询重复投递。
            server_lines="    uidl"
            user_lines=""
            if [ "$FETCH_MODE" = idle ]; then
                echo "[$ACCOUNT_NAME] POP3 does not support IDLE; using poll every ${POLL_INTERVAL}s" >&2
                FETCH_MODE=poll
            fi
            ;;
        *)
            echo "[$ACCOUNT_NAME] ERROR: PROTOCOL must be IMAP or POP3" >&2
            return 2
            ;;
    esac
    POLL_INTERVAL="${POLL_INTERVAL:-60}"
    IDLE_TIMEOUT="${IDLE_TIMEOUT:-1680}"
    LOCAL_RECIPIENT="${LOCAL_RECIPIENT:-$DEFAULT_LOCAL_RECIPIENT}"
    BATCH_LIMIT="${BATCH_LIMIT:-$SMTP_BATCH_LIMIT}"
    FETCH_ALL_FIRST_RAW="${FETCH_ALL_ON_FIRST_RUN:-$GLOBAL_FETCH_ALL_FIRST}"
    FETCH_ALL_FIRST="$(bool_value "$FETCH_ALL_FIRST_RAW")" || {
        echo "[$ACCOUNT_NAME] ERROR: FETCH_ALL_ON_FIRST_RUN must be true/false" >&2
        return 2
    }

    [ -n "$LOCAL_RECIPIENT" ] || {
        echo "[$ACCOUNT_NAME] LOCAL_RECIPIENT is empty" >&2
        return 2
    }

    state_dir="$DATA_DIR/$ACCOUNT_NAME"
    mkdir -p "$state_dir"
    chown 10001:10001 "$state_dir"
    chmod 0750 "$state_dir"

    rc="$state_dir/fetchmailrc"
    pidfile="$state_dir/fetchmail.pid"
    initial_pidfile="$state_dir/fetchmail-initial.pid"
    idfile="$state_dir/fetchids"
    initial_marker="$state_dir/.initial-fetchall-complete"
    rm -f "$pidfile" "$initial_pidfile"

    user_esc="$(escape_fetchmail "$IMAP_USER")"
    pass_esc="$(escape_fetchmail "$IMAP_PASSWORD")"
    target_esc="$(escape_fetchmail "$LOCAL_RECIPIENT")"
    pop3_baseline_marker="$state_dir/.pop3-baseline-complete"

    cat > "$rc" <<RC
set no syslog
set softbounce

poll ${IMAP_HOST}
    protocol ${PROTOCOL}
    port ${IMAP_PORT}
${server_lines}
    user "${user_esc}"
    password "${pass_esc}"
    batchlimit ${BATCH_LIMIT}
${user_lines}
    ssl
    sslproto TLS1.2+
    sslcertck
    keep
    no rewrite
    smtphost "${SMTP_HOST}/${SMTP_PORT}"
    smtpname "${target_esc}"
RC

    chmod 600 "$rc"
    chown 10001:10001 "$rc"

    # 只做解析预检。Fetchmail 对配置项顺序要求严格，尽量在正式运行前提前失败。
    if ! HOME="$state_dir" FETCHMAILHOME="$state_dir" su-exec 10001:10001 fetchmail \
        --configdump -f "$rc" >/dev/null; then
        echo "[$ACCOUNT_NAME] ERROR: generated fetchmailrc failed syntax validation: $rc" >&2
        return 2
    fi

    echo "[$ACCOUNT_NAME] ${PROTOCOL} ${IMAP_USER}@${IMAP_HOST}:${IMAP_PORT} folder=${IMAP_FOLDER} mode=${FETCH_MODE} batch=${BATCH_LIMIT} -> ${LOCAL_RECIPIENT}"

    # POP3 没有 \Seen 标记：uidl 记录为空时，Fetchmail 会把服务器上的全部邮件当作新邮件。
    # 未开启历史导入时，首次只记录现有邮件 UID（交给丢弃型 MDA，不投递），之后只收新邮件。
    while [ "$PROTOCOL" = POP3 ] && [ "$FETCH_ALL_FIRST" = false ] && [ ! -f "$pop3_baseline_marker" ]; do
        echo "[$ACCOUNT_NAME] POP3 first run: recording existing message UIDs without delivering them"
        set +e
        HOME="$state_dir" FETCHMAILHOME="$state_dir" su-exec 10001:10001 fetchmail \
            --nodetach -f "$rc" --pidfile "$initial_pidfile" --idfile "$idfile" \
            --mda "cat >/dev/null"
        baseline_status=$?
        set -e
        rm -f "$initial_pidfile"
        case "$baseline_status" in
            0|1)
                : > "$pop3_baseline_marker"
                chown 10001:10001 "$pop3_baseline_marker"
                echo "[$ACCOUNT_NAME] POP3 baseline complete; only new mail will be delivered"
                ;;
            *)
                # 不能跳过基线直接进入轮询，否则会把全部历史邮件当新邮件投递。
                echo "[$ACCOUNT_NAME] ERROR: POP3 baseline failed with fetchmail status ${baseline_status}; retry in 60s" >&2
                sleep 60
                ;;
        esac
    done

    # 只有显式开启 FETCH_ALL_ON_FIRST_RUN 时才执行一次前台 --fetchall。
    # Fetchmail 的普通 IMAP 模式会跳过上游已经标记为 \Seen 的邮件；
    # --fetchall 用于可选的历史邮件首次导入。返回 0（取到邮件）或 1（无邮件）后
    # 写入 marker，之后所有启动都回到普通 IDLE/poll，只处理新邮件。
    if [ "$FETCH_ALL_FIRST" = true ] && [ ! -f "$initial_marker" ]; then
        echo "[$ACCOUNT_NAME] first-run history import: fetching all messages in ${IMAP_FOLDER}"
        set +e
        HOME="$state_dir" FETCHMAILHOME="$state_dir" su-exec 10001:10001 fetchmail \
            --nodetach -f "$rc" --pidfile "$initial_pidfile" --idfile "$idfile" \
            --fetchall
        initial_status=$?
        set -e
        rm -f "$initial_pidfile"
        case "$initial_status" in
            0|1)
                : > "$initial_marker"
                chown 10001:10001 "$initial_marker"
                echo "[$ACCOUNT_NAME] first-run history import complete"
                ;;
            *)
                echo "[$ACCOUNT_NAME] ERROR: first-run history import failed with fetchmail status ${initial_status}; marker not written" >&2
                return "$initial_status"
                ;;
        esac
    fi

    while true; do
        rm -f "$pidfile"
        case "$FETCH_MODE" in
            idle)
                HOME="$state_dir" FETCHMAILHOME="$state_dir" su-exec 10001:10001 fetchmail \
                    --nodetach -f "$rc" --pidfile "$pidfile" --idfile "$idfile" \
                    --daemon "$POLL_INTERVAL" --idle --idletimeout "$IDLE_TIMEOUT" || true
                ;;
            poll)
                HOME="$state_dir" FETCHMAILHOME="$state_dir" su-exec 10001:10001 fetchmail \
                    --nodetach -f "$rc" --pidfile "$pidfile" --idfile "$idfile" \
                    --daemon "$POLL_INTERVAL" || true
                ;;
            *)
                echo "[$ACCOUNT_NAME] ERROR: FETCH_MODE must be idle or poll" >&2
                return 2
                ;;
        esac
        rm -f "$pidfile"
        echo "[$ACCOUNT_NAME] exited; restart in 5s" >&2
        sleep 5
    done
}

pids=""
stop_all() {
    echo "[collector] stopping..."
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    wait || true
}
trap stop_all INT TERM

found=0
for cfg in "$ACCOUNTS_DIR"/*.env; do
    [ -f "$cfg" ] || continue
    case "$(basename "$cfg")" in
        *.example.env|*.disabled.env) continue ;;
    esac
    found=1
    worker "$cfg" &
    pids="$pids $!"
done

if [ "$found" -eq 0 ]; then
    echo "[collector] no active account configs; waiting (this is valid on a fresh install)"
    touch "$DATA_DIR/.healthy"
    chown 10001:10001 "$DATA_DIR/.healthy"
    while true; do sleep 3600; done
fi

touch "$DATA_DIR/.healthy"
chown 10001:10001 "$DATA_DIR/.healthy"
wait
