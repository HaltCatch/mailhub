#!/bin/sh
set -eu

# Docker 会把缺失的 bind mount 源目录创建为 root:root。这里只处理挂载根目录，
# 然后立即降回 Stalwart 上游 UID/GID 2000；不会对整个邮件数据库递归 chown。
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p /etc/stalwart /var/lib/stalwart /var/lib/stalwart/.cli-home
  chown 2000:2000 /etc/stalwart /var/lib/stalwart /var/lib/stalwart/.cli-home
  chmod 0750 /etc/stalwart /var/lib/stalwart /var/lib/stalwart/.cli-home
  if command -v gosu >/dev/null 2>&1; then
    exec gosu 2000:2000 "$0" "$@"
  elif command -v su-exec >/dev/null 2>&1; then
    exec su-exec 2000:2000 "$0" "$@"
  fi
  echo "[mailhub] ERROR: no privilege-drop helper available" >&2
  exit 1
fi

CONFIG=/etc/stalwart/config.json
MARKER=/var/lib/stalwart/.mailhub-provisioned-v1.3
HOSTNAME="${MAIL_HUB_HOSTNAME:?MAIL_HUB_HOSTNAME is required}"
DOMAIN="${HUB_DOMAIN:?HUB_DOMAIN is required}"
LOCAL_PART="${HUB_ADMIN_LOCAL_PART:-admin}"
ADMIN_PASSWORD="${STALWART_ADMIN_PASSWORD:?STALWART_ADMIN_PASSWORD is required}"
MANAGE_TRUST="${MAIL_HUB_MANAGE_COLLECTOR_TRUST:-true}"
BOOT_USER="bootstrap-admin"
TIMEOUT="${MAIL_HUB_BOOTSTRAP_TIMEOUT:-180}"
REQUEST_TLS="${STALWART_REQUEST_TLS_CERTIFICATE:-false}"
COLLECTOR_PORT="${MAIL_HUB_COLLECTOR_SMTP_PORT:-2525}"
OIDC_ENABLED="${MAIL_HUB_OIDC_ENABLED:-false}"
OIDC_ISSUER_URL="${MAIL_HUB_OIDC_ISSUER_URL:-}"
OIDC_CLIENT_ID="${MAIL_HUB_OIDC_CLIENT_ID:-}"
OIDC_USERNAME_CLAIM="${MAIL_HUB_OIDC_USERNAME_CLAIM:-email}"
OIDC_USERNAME_DOMAIN="${MAIL_HUB_OIDC_USERNAME_DOMAIN:-}"
OIDC_NAME_CLAIM="${MAIL_HUB_OIDC_NAME_CLAIM:-name}"
OIDC_STATE=/var/lib/stalwart/.mailhub-oidc-state
AUTOMATION_KEY_FILE=/var/lib/stalwart/.mailhub-automation-key
RELAY_STATE=/var/lib/stalwart/.mailhub-relay-state
DNS_STATE=/var/lib/stalwart/.mailhub-dns-state
RELAY_ENABLED="${MAIL_HUB_RELAY_ENABLED:-false}"
RELAY_HOST="${MAIL_HUB_RELAY_HOST:-}"
RELAY_PORT="${MAIL_HUB_RELAY_PORT:-587}"
RELAY_IMPLICIT_TLS="${MAIL_HUB_RELAY_IMPLICIT_TLS:-false}"
RELAY_USERNAME="${MAIL_HUB_RELAY_USERNAME:-}"
DNS_SERVERS="$(printf '%s' "${MAIL_HUB_DNS_SERVERS:-}" | tr -d ' ')"
RULES_UPDATE_HOURS="${MAIL_HUB_SPAM_RULES_UPDATE_HOURS:-168}"
RULES_UPDATE_DELAY="${MAIL_HUB_SPAM_RULES_UPDATE_DELAY_SECONDS:-300}"
NEUTRAL_TAGS="$(printf '%s' "${MAIL_HUB_COLLECTOR_NEUTRAL_TAGS-HELO_NOT_FQDN,HELO_NORES_A_OR_MX,FORGED_RECIPIENTS,FORGED_RCVD_TRAIL,DMARC_NA,RCVD_NO_TLS_LAST}" | tr -d ' ')"
ROLE_BINDINGS_STATE=/var/lib/stalwart/.mailhub-role-bindings-v2
# Bootstrap/recovery API 仅供容器内编排使用，故意不复用公开的 8080。
# 这样反代在冷启动期间不会把浏览器/OIDC 请求误送进 recovery listener。
INTERNAL_MGMT_PORT=18080
# Stalwart 会在第一次“正常模式”启动时物化内置 Role。冷启动时先用
# loopback-only HTTP listener 完成这一阶段，再切回最终 0.0.0.0:8080。
ROLE_SEED_PORT=18081

export HOME=/var/lib/stalwart/.cli-home
mkdir -p "$HOME"

case "$REQUEST_TLS" in
  true|false) ;;
  *) echo "[mailhub] ERROR: STALWART_REQUEST_TLS_CERTIFICATE must be true or false" >&2; exit 2 ;;
esac
case "$MANAGE_TRUST" in
  true|false) ;;
  *) echo "[mailhub] ERROR: MAIL_HUB_MANAGE_COLLECTOR_TRUST must be true or false" >&2; exit 2 ;;
esac
case "$OIDC_ENABLED" in
  true|false) ;;
  *) echo "[mailhub] ERROR: MAIL_HUB_OIDC_ENABLED must be true or false" >&2; exit 2 ;;
esac
if [ "$OIDC_ENABLED" = true ]; then
  [ -n "$OIDC_ISSUER_URL" ] || { echo "[mailhub] ERROR: MAIL_HUB_OIDC_ISSUER_URL is required when OIDC is enabled" >&2; exit 2; }
  [ -n "$OIDC_CLIENT_ID" ] || { echo "[mailhub] ERROR: MAIL_HUB_OIDC_CLIENT_ID is required when OIDC is enabled" >&2; exit 2; }
  [ -n "$OIDC_USERNAME_CLAIM" ] || { echo "[mailhub] ERROR: MAIL_HUB_OIDC_USERNAME_CLAIM must not be empty" >&2; exit 2; }
fi
for flag in "MAIL_HUB_RELAY_ENABLED=$RELAY_ENABLED" "MAIL_HUB_RELAY_IMPLICIT_TLS=$RELAY_IMPLICIT_TLS"; do
  case "${flag#*=}" in
    true|false) ;;
    *) echo "[mailhub] ERROR: ${flag%%=*} must be true or false" >&2; exit 2 ;;
  esac
done
if [ "$RELAY_ENABLED" = true ]; then
  [ -n "$RELAY_HOST" ] || { echo "[mailhub] ERROR: MAIL_HUB_RELAY_HOST is required when relay is enabled" >&2; exit 2; }
  if [ -n "$RELAY_USERNAME" ] && [ -z "${MAIL_HUB_RELAY_PASSWORD:-}" ]; then
    echo "[mailhub] ERROR: MAIL_HUB_RELAY_PASSWORD is required when MAIL_HUB_RELAY_USERNAME is set" >&2; exit 2
  fi
fi
for num in "MAIL_HUB_RELAY_PORT=$RELAY_PORT" "MAIL_HUB_SPAM_RULES_UPDATE_HOURS=$RULES_UPDATE_HOURS" "MAIL_HUB_SPAM_RULES_UPDATE_DELAY_SECONDS=$RULES_UPDATE_DELAY"; do
  case "${num#*=}" in
    ''|*[!0-9]*) echo "[mailhub] ERROR: ${num%%=*} must be a non-negative integer" >&2; exit 2 ;;
  esac
done
case "$COLLECTOR_PORT" in
  ''|*[!0-9]*) echo "[mailhub] ERROR: MAIL_HUB_COLLECTOR_SMTP_PORT must be an integer" >&2; exit 2 ;;
  *) if [ "$COLLECTOR_PORT" -lt 1 ] || [ "$COLLECTOR_PORT" -gt 65535 ]; then echo "[mailhub] ERROR: invalid collector SMTP port: $COLLECTOR_PORT" >&2; exit 2; fi ;;
esac

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

wait_http() {
  limit="$1"
  port="${2:-8080}"
  i=0
  while [ "$i" -lt "$limit" ]; do
    if curl -fsS "http://127.0.0.1:${port}/healthz/live" >/dev/null 2>&1 || \
       curl -fsS "http://127.0.0.1:${port}/admin" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

stop_child() {
  child="$1"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}

start_bootstrap() {
  echo "[mailhub] fresh Stalwart data detected; starting one-time bootstrap"
  STALWART_RECOVERY_MODE_PORT="${INTERNAL_MGMT_PORT}" \
  STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
    /usr/local/bin/stalwart "$@" &
  child=$!

  if ! wait_http "$TIMEOUT" "$INTERNAL_MGMT_PORT"; then
    echo "[mailhub] ERROR: Stalwart bootstrap listener did not become ready" >&2
    stop_child "$child"
    exit 1
  fi

  export STALWART_URL="http://127.0.0.1:${INTERNAL_MGMT_PORT}"
  export STALWART_USER="$BOOT_USER"
  export STALWART_PASSWORD="$ADMIN_PASSWORD"
  /usr/local/bin/stalwart-cli update Bootstrap \
    --field "serverHostname=${HOSTNAME}" \
    --field "defaultDomain=${DOMAIN}" \
    --field "requestTlsCertificate=${REQUEST_TLS}" \
    --field "generateDkimKeys=true" \
    --field 'directory={"@type":"Internal"}' \
    --field 'dnsServer={"@type":"Manual"}'

  i=0
  while [ ! -s "$CONFIG" ] && [ "$i" -lt "$TIMEOUT" ]; do
    i=$((i + 1))
    sleep 1
  done
  if [ ! -s "$CONFIG" ]; then
    echo "[mailhub] ERROR: bootstrap API returned but config.json was not created" >&2
    stop_child "$child"
    exit 1
  fi

  stop_child "$child"
  unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN
  echo "[mailhub] bootstrap complete"
}

provision_once() {
  [ -f "$MARKER" ] && return 0

  echo "[mailhub] reconciling the single local mailbox: ${LOCAL_PART}@${DOMAIN}"
  STALWART_RECOVERY_MODE=1 \
  STALWART_RECOVERY_MODE_PORT="${INTERNAL_MGMT_PORT}" \
  STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
    /usr/local/bin/stalwart "$@" &
  child=$!

  if ! wait_http "$TIMEOUT" "$INTERNAL_MGMT_PORT"; then
    echo "[mailhub] ERROR: recovery listener did not become ready" >&2
    stop_child "$child"
    exit 1
  fi

  export STALWART_URL="http://127.0.0.1:${INTERNAL_MGMT_PORT}"
  export STALWART_USER="$BOOT_USER"
  export STALWART_PASSWORD="$ADMIN_PASSWORD"

  domain_esc="$(json_escape "$DOMAIN")"
  host_esc="$(json_escape "$HOSTNAME")"
  local_esc="$(json_escape "$LOCAL_PART")"
  pass_esc="$(json_escape "$ADMIN_PASSWORD")"
  collector_bind="0.0.0.0:${COLLECTOR_PORT}"
  seed_jmap_bind="127.0.0.1:${ROLE_SEED_PORT}"
  plan=/var/lib/stalwart/.mailhub-plan.ndjson

  cat > "$plan" <<EOF_PLAN
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"hub-domain":{"name":"${domain_esc}","description":"Private Mail Hub domain"}}}
{"@type":"upsert","object":"Account","matchOn":["name","domainId"],"value":{"hub-admin":{"@type":"User","name":"${local_esc}","domainId":"#hub-domain","credentials":{"0":{"@type":"Password","secret":"${pass_esc}"}},"roles":{"@type":"Admin"}}}}
{"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#hub-domain","defaultHostname":"${host_esc}"}}
EOF_PLAN

  # 专用 listener 属于固定传输拓扑，与下面是否启用可选信任放宽策略无关。
  cat >> "$plan" <<EOF_PLAN
{"@type":"upsert","object":"NetworkListener","matchOn":["name"],"value":{"mailhub-collector":{"name":"mailhub-collector","bind":{"${collector_bind}":true},"protocol":"smtp","useTls":false,"tlsImplicit":false,"overrideProxyTrustedNetworks":{},"tlsDisableCipherSuites":{},"tlsDisableProtocols":{}}}}
{"@type":"upsert","object":"NetworkListener","matchOn":["name"],"value":{"mailhub-jmap":{"name":"mailhub-jmap","bind":{"${seed_jmap_bind}":true},"protocol":"http","useTls":false,"tlsImplicit":false,"overrideProxyTrustedNetworks":{},"tlsDisableCipherSuites":{},"tlsDisableProtocols":{}}}}
{"@type":"update","object":"SpamSettings","value":{"enable":true,"scoreSpam":5,"scoreDiscard":0,"scoreReject":0,"trustContacts":true,"trustReplies":true}}
EOF_PLAN

  if [ "$MANAGE_TRUST" = true ]; then
    # 安全策略放宽只限定在 Collector 专用内部端口。
    # 2525 不发布到宿主机，因此无需硬编码 Docker 子网，也不会影响未来的公网 SMTP listener。
    cat >> "$plan" <<EOF_PLAN
{"@type":"update","object":"MtaStageAuth","value":{"require":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"false"}},"else":"local_port != 25"}}}
{"@type":"update","object":"SenderAuth","value":{"spfEhloVerify":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"disable"},"1":{"if":"listener == 'smtp'","then":"relaxed"}},"else":"disable"},"spfFromVerify":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"disable"},"1":{"if":"listener == 'smtp'","then":"relaxed"}},"else":"disable"},"dmarcVerify":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"disable"},"1":{"if":"listener == 'smtp'","then":"relaxed"}},"else":"disable"},"reverseIpVerify":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"disable"},"1":{"if":"listener == 'smtp'","then":"relaxed"}},"else":"disable"}}}
{"@type":"update","object":"MtaStageData","value":{"maxMessages":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"1000"}},"else":"10"},"enableSpamFilter":{"match":{"0":{"if":"local_port == ${COLLECTOR_PORT}","then":"true"}},"else":"is_empty(authenticated_as)"}}}
EOF_PLAN
  fi

  /usr/local/bin/stalwart-cli apply --file "$plan" --json
  rm -f "$plan"

  # Bulwark 位于 mail.*，JMAP 位于 hub.*，浏览器会跨 Origin 访问公开 JMAP。
  # 因此这里开启 Stalwart permissive CORS；该更新路径已在 Stalwart 0.16.21 实机验证。
  /usr/local/bin/stalwart-cli update Http --field usePermissiveCors=true
  echo "[mailhub] permissive CORS enabled for public JMAP access"

  # Stalwart 可能缓存了账号创建前的负向查询结果，这里主动刷新缓存。
  /usr/local/bin/stalwart-cli create Action --json '{"@type":"InvalidateCaches"}' >/dev/null 2>&1 || \
    echo "[mailhub] warning: cache invalidation action was not available; authentication cache will expire normally" >&2

  # Stalwart 0.16.21 会拒绝 Bootstrap 阶段的嵌套 tracer 更新。
  # 因此改在 recovery 模式统一规范化为唯一一个 Docker Stdout tracer。
  echo "[mailhub] normalizing telemetry tracer to one Docker Stdout tracer"
  tracer_ids="$(
    /usr/local/bin/stalwart-cli query Tracer --fields "id,@type" --json 2>/dev/null \
      | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' \
      | awk 'BEGIN{s=""} {printf "%s%s",s,$0; s=","} END{print ""}'
  )"

  if [ -n "$tracer_ids" ]; then
    echo "[mailhub] deleting existing tracer(s): $tracer_ids"
    /usr/local/bin/stalwart-cli delete Tracer --ids "$tracer_ids"
  fi

  /usr/local/bin/stalwart-cli create Tracer/Stdout \
    --field ansi=false \
    --field multiline=false \
    --field buffered=true \
    --field enable=true \
    --field level=info \
    --field lossy=false

  echo "[mailhub] Stdout tracer created"

  touch "$MARKER"
  stop_child "$child"
  unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN STALWART_RECOVERY_MODE
  echo "[mailhub] admin mailbox ready; temporary recovery credential removed before normal startup"
}

reconcile_default_role_bindings() {
  # Stalwart 0.16 的 Bootstrap 会先写出配置/基础对象，但内置 Role 对象是在
  # 第一次正常模式启动时物化的。因此不能在 Bootstrap 后立刻假设 Role 已存在。
  #
  # 冷启动顺序：
  #   1) recovery(18080) 检查 Role；
  #   2) 若缺失，让正常服务只在 loopback:18081 启动一次以物化内置 Role；
  #   3) recovery(18080) 绑定 Authentication.default*RoleIds，并把 JMAP listener
  #      切回最终的 0.0.0.0:8080；
  #   4) 后续才配置可选 OIDC，最后正式启动。
  #
  # 18080/18081 都不会通过 Compose 发布，避免冷启动期间反代把真实浏览器
  # token 误送进 recovery listener（这会产生无意义的 token decode 错误日志）。
  [ -f "$ROLE_BINDINGS_STATE" ] && return 0

  role_id_by_description() {
    role_description="$1"
    /usr/local/bin/stalwart-cli query Role --fields "id,description" --json 2>/dev/null \
      | while IFS= read -r role_line; do
          case "$role_line" in
            *"\"description\":\"${role_description}\""*)
              printf '%s\n' "$role_line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
              break
              ;;
          esac
        done
  }

  start_internal_recovery() {
    STALWART_RECOVERY_MODE=1 \
    STALWART_RECOVERY_MODE_PORT="${INTERNAL_MGMT_PORT}" \
    STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
      /usr/local/bin/stalwart "$@" &
    child=$!

    if ! wait_http "$TIMEOUT" "$INTERNAL_MGMT_PORT"; then
      echo "[mailhub] ERROR: internal recovery listener did not become ready" >&2
      stop_child "$child"
      exit 1
    fi

    export STALWART_URL="http://127.0.0.1:${INTERNAL_MGMT_PORT}"
    export STALWART_USER="$BOOT_USER"
    export STALWART_PASSWORD="$ADMIN_PASSWORD"
  }

  resolve_builtin_roles() {
    user_role_id="$(role_id_by_description 'User')"
    group_role_id="$(role_id_by_description 'Group')"
    admin_role_id="$(role_id_by_description 'System Administrator')"
  }

  echo "[mailhub] reconciling Stalwart default role bindings"
  start_internal_recovery "$@"
  resolve_builtin_roles

  if [ -z "$user_role_id" ] || [ -z "$group_role_id" ] || [ -z "$admin_role_id" ]; then
    echo "[mailhub] built-in roles are not materialized yet; running one loopback-only normal initialization"

    # 确保第一次正常模式启动不会占用公开的 8080。
    seed_plan=/var/lib/stalwart/.mailhub-role-seed-listener.ndjson
    cat > "$seed_plan" <<EOF_ROLE_SEED
{"@type":"upsert","object":"NetworkListener","matchOn":["name"],"value":{"mailhub-jmap":{"name":"mailhub-jmap","bind":{"127.0.0.1:${ROLE_SEED_PORT}":true},"protocol":"http","useTls":false,"tlsImplicit":false,"overrideProxyTrustedNetworks":{},"tlsDisableCipherSuites":{},"tlsDisableProtocols":{}}}}
EOF_ROLE_SEED
    /usr/local/bin/stalwart-cli apply --file "$seed_plan" --json
    rm -f "$seed_plan"

    stop_child "$child"
    unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_MODE STALWART_RECOVERY_MODE_PORT

    # Recovery admin 仅在这个一次性初始化子进程存活期间存在；官方允许它在正常
    # 模式下用于恢复/自动化，但最终正式服务启动前会彻底 unset。
    STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
      /usr/local/bin/stalwart "$@" &
    child=$!

    if ! wait_http "$TIMEOUT" "$ROLE_SEED_PORT"; then
      echo "[mailhub] ERROR: role-seed normal listener did not become ready" >&2
      stop_child "$child"
      exit 1
    fi

    export STALWART_URL="http://127.0.0.1:${ROLE_SEED_PORT}"
    export STALWART_USER="$BOOT_USER"
    export STALWART_PASSWORD="$ADMIN_PASSWORD"

    i=0
    while [ "$i" -lt "$TIMEOUT" ]; do
      resolve_builtin_roles
      if [ -n "$user_role_id" ] && [ -n "$group_role_id" ] && [ -n "$admin_role_id" ]; then
        break
      fi
      i=$((i + 1))
      sleep 1
    done

    stop_child "$child"
    unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN

    # 用隔离的 recovery listener 做最终写入，避免在正常服务阶段修改核心认证对象。
    start_internal_recovery "$@"
    resolve_builtin_roles
  fi

  if [ -z "$user_role_id" ] || [ -z "$group_role_id" ] || [ -z "$admin_role_id" ]; then
    echo "[mailhub] ERROR: required built-in Stalwart roles were not found after normal initialization" >&2
    echo "[mailhub] resolved roles: user=${user_role_id:-missing}, group=${group_role_id:-missing}, admin=${admin_role_id:-missing}" >&2
    stop_child "$child"
    exit 1
  fi

  /usr/local/bin/stalwart-cli update Authentication \
    --field "defaultUserRoleIds={\"${user_role_id}\":true}" \
    --field "defaultGroupRoleIds={\"${group_role_id}\":true}" \
    --field "defaultAdminRoleIds={\"${admin_role_id}\":true,\"${user_role_id}\":true}"

  # role seed 阶段使用的是 loopback-only listener；现在切回最终公开 JMAP 监听。
  final_listener_plan=/var/lib/stalwart/.mailhub-final-jmap-listener.ndjson
  cat > "$final_listener_plan" <<'EOF_FINAL_LISTENER'
{"@type":"upsert","object":"NetworkListener","matchOn":["name"],"value":{"mailhub-jmap":{"name":"mailhub-jmap","bind":{"0.0.0.0:8080":true},"protocol":"http","useTls":false,"tlsImplicit":false,"overrideProxyTrustedNetworks":{},"tlsDisableCipherSuites":{},"tlsDisableProtocols":{}}}}
EOF_FINAL_LISTENER
  /usr/local/bin/stalwart-cli apply --file "$final_listener_plan" --json
  rm -f "$final_listener_plan"

  /usr/local/bin/stalwart-cli create Action --json '{"@type":"InvalidateCaches"}' >/dev/null 2>&1 || true
  printf '%s\n' "user=${user_role_id} group=${group_role_id} admin=${admin_role_id}+${user_role_id}" > "$ROLE_BINDINGS_STATE"
  chmod 0600 "$ROLE_BINDINGS_STATE"

  stop_child "$child"
  unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN STALWART_RECOVERY_MODE STALWART_RECOVERY_MODE_PORT
  echo "[mailhub] default role bindings ready: User=${user_role_id}, Group=${group_role_id}, Admin=${admin_role_id}+${user_role_id}"
}

reconcile_oidc() {
  # OIDC 是可选能力，并且允许在首次部署之后再开启。
  # 因此它不能依赖一次性的 provisioning marker，而是只在配置发生变化时重放。
  if [ "$OIDC_ENABLED" = false ]; then
    if [ ! -f "$OIDC_STATE" ] || [ "$(cat "$OIDC_STATE" 2>/dev/null || true)" = "disabled" ]; then
      return 0
    fi
    desired_state="disabled"
  else
    desired_state="enabled|${OIDC_ISSUER_URL}|${OIDC_CLIENT_ID}|${OIDC_USERNAME_CLAIM}|${OIDC_USERNAME_DOMAIN}|${OIDC_NAME_CLAIM}"
    if [ -f "$OIDC_STATE" ] && [ "$(cat "$OIDC_STATE" 2>/dev/null || true)" = "$desired_state" ]; then
      return 0
    fi
  fi

  echo "[mailhub] reconciling optional OIDC authentication"
  STALWART_RECOVERY_MODE=1 \
  STALWART_RECOVERY_MODE_PORT="${INTERNAL_MGMT_PORT}" \
  STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
    /usr/local/bin/stalwart "$@" &
  child=$!

  if ! wait_http "$TIMEOUT" "$INTERNAL_MGMT_PORT"; then
    echo "[mailhub] ERROR: recovery listener did not become ready for OIDC reconciliation" >&2
    stop_child "$child"
    exit 1
  fi

  export STALWART_URL="http://127.0.0.1:${INTERNAL_MGMT_PORT}"
  export STALWART_USER="$BOOT_USER"
  export STALWART_PASSWORD="$ADMIN_PASSWORD"
  plan=/var/lib/stalwart/.mailhub-oidc-plan.ndjson

  if [ "$OIDC_ENABLED" = true ]; then
    issuer_esc="$(json_escape "$OIDC_ISSUER_URL")"
    client_esc="$(json_escape "$OIDC_CLIENT_ID")"
    username_claim_esc="$(json_escape "$OIDC_USERNAME_CLAIM")"
    name_claim_esc="$(json_escape "$OIDC_NAME_CLAIM")"

    if [ -n "$OIDC_USERNAME_DOMAIN" ]; then
      username_domain_esc="$(json_escape "$OIDC_USERNAME_DOMAIN")"
      username_domain_json=",\"usernameDomain\":\"${username_domain_esc}\""
    else
      username_domain_json=""
    fi

    cat > "$plan" <<EOF_OIDC
{"@type":"upsert","object":"Directory","matchOn":["description"],"value":{"mailhub-oidc":{"@type":"Oidc","description":"MailHub external OIDC","issuerUrl":"${issuer_esc}","requireAudience":"${client_esc}","requireScopes":{"openid":true,"email":true},"claimUsername":"${username_claim_esc}"${username_domain_json},"claimName":"${name_claim_esc}"}}}
{"@type":"update","object":"Authentication","value":{"directoryId":"#mailhub-oidc"}}
EOF_OIDC
  else
    # 仅当这个项目以前管理过 OIDC 时才走到这里；关闭开关即可恢复 Stalwart 内部目录。
    cat > "$plan" <<'EOF_OIDC'
{"@type":"update","object":"Authentication","value":{"directoryId":null}}
EOF_OIDC
  fi

  /usr/local/bin/stalwart-cli apply --file "$plan" --json
  rm -f "$plan"
  /usr/local/bin/stalwart-cli create Action --json '{"@type":"InvalidateCaches"}' >/dev/null 2>&1 || true

  printf '%s' "$desired_state" > "$OIDC_STATE"
  chmod 0600 "$OIDC_STATE"
  stop_child "$child"
  unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN STALWART_RECOVERY_MODE

  if [ "$OIDC_ENABLED" = true ]; then
    echo "[mailhub] OIDC directory enabled; access-token audience=${OIDC_CLIENT_ID}, username-claim=${OIDC_USERNAME_CLAIM}"
  else
    echo "[mailhub] OIDC directory disabled; internal directory restored"
  fi
}

reconcile_options() {
  # 1.4.0 新增的三项都在一次 recovery 会话内完成，并且只在状态变化时才启动 recovery：
  #   - automation API key：供 trainer 与规则定时更新使用。开启 OIDC 后 admin 密码
  #     不再能通过 Basic 认证，但账号自己的 ApiKey（Bearer）仍然有效（0.16.21 实测）。
  #   - 可选 SMTP Smart Host（MtaRoute/Relay）。密码通过 EnvironmentVariable 引用，
  #     不写入 Stalwart 配置库，因此修改密码只需重建容器，不需要重新 reconcile。
  #   - 可选自定义 DNS 递归解析器（DnsResolver/Custom）。
  need_key=false
  [ -s "$AUTOMATION_KEY_FILE" ] || need_key=true

  if [ "$RELAY_ENABLED" = true ]; then
    relay_desired="enabled|${RELAY_HOST}|${RELAY_PORT}|${RELAY_IMPLICIT_TLS}|${RELAY_USERNAME}"
  else
    relay_desired="disabled"
  fi
  relay_current="$(cat "$RELAY_STATE" 2>/dev/null || echo disabled)"

  dns_desired="${DNS_SERVERS:-system}"
  dns_current="$(cat "$DNS_STATE" 2>/dev/null || echo system)"

  if [ "$need_key" = false ] && [ "$relay_desired" = "$relay_current" ] && [ "$dns_desired" = "$dns_current" ]; then
    return 0
  fi

  echo "[mailhub] reconciling automation key / outbound relay / DNS resolver"
  STALWART_RECOVERY_MODE=1 \
  STALWART_RECOVERY_MODE_PORT="${INTERNAL_MGMT_PORT}" \
  STALWART_RECOVERY_ADMIN="${BOOT_USER}:${ADMIN_PASSWORD}" \
    /usr/local/bin/stalwart "$@" &
  child=$!

  if ! wait_http "$TIMEOUT" "$INTERNAL_MGMT_PORT"; then
    echo "[mailhub] ERROR: recovery listener did not become ready for option reconciliation" >&2
    stop_child "$child"
    exit 1
  fi

  export STALWART_URL="http://127.0.0.1:${INTERNAL_MGMT_PORT}"
  export STALWART_USER="$BOOT_USER"
  export STALWART_PASSWORD="$ADMIN_PASSWORD"

  if [ "$need_key" = true ]; then
    account_id="$(
      /usr/local/bin/stalwart-cli query Account --fields "id,name" --json 2>/dev/null \
        | grep -F "\"name\":\"${LOCAL_PART}\"" | head -1 | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
    )"
    if [ -z "$account_id" ]; then
      echo "[mailhub] ERROR: account ${LOCAL_PART} not found; cannot create automation API key" >&2
      stop_child "$child"
      exit 1
    fi
    key_response="$(
      curl -fsS -u "${BOOT_USER}:${ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
        "http://127.0.0.1:${INTERNAL_MGMT_PORT}/jmap/" \
        -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:stalwart:jmap\"],\"methodCalls\":[[\"x:ApiKey/set\",{\"accountId\":\"${account_id}\",\"create\":{\"k\":{\"description\":\"mailhub-automation\"}}},\"a\"]]}"
    )"
    key_secret="$(printf '%s' "$key_response" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p')"
    if [ -z "$key_secret" ]; then
      echo "[mailhub] ERROR: automation API key creation failed: $key_response" >&2
      stop_child "$child"
      exit 1
    fi
    (umask 077; printf '%s' "$key_secret" > "$AUTOMATION_KEY_FILE")
    echo "[mailhub] automation API key created for account ${LOCAL_PART}@${DOMAIN}"
  fi

  if [ "$relay_desired" != "$relay_current" ]; then
    plan=/var/lib/stalwart/.mailhub-relay-plan.ndjson
    if [ "$RELAY_ENABLED" = true ]; then
      if [ -n "$RELAY_USERNAME" ]; then
        relay_auth="\"authUsername\":\"$(json_escape "$RELAY_USERNAME")\",\"authSecret\":{\"@type\":\"EnvironmentVariable\",\"variableName\":\"MAIL_HUB_RELAY_PASSWORD\"}"
      else
        relay_auth="\"authUsername\":null,\"authSecret\":{\"@type\":\"None\"}"
      fi
      cat > "$plan" <<EOF_RELAY
{"@type":"upsert","object":"MtaRoute","matchOn":["name"],"value":{"mailhub-relay":{"@type":"Relay","name":"mailhub-relay","description":"MailHub SMTP smart host","address":"$(json_escape "$RELAY_HOST")","port":${RELAY_PORT},"protocol":"smtp","implicitTls":${RELAY_IMPLICIT_TLS},"allowInvalidCerts":false,${relay_auth}}}}
{"@type":"update","object":"MtaOutboundStrategy","value":{"route":{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'mailhub-relay'"}}}
EOF_RELAY
    else
      # 关闭时恢复 Stalwart 默认直投 MX；Relay 路由对象保留但不再被引用。
      cat > "$plan" <<'EOF_RELAY'
{"@type":"update","object":"MtaOutboundStrategy","value":{"route":{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'mx'"}}}
EOF_RELAY
    fi
    /usr/local/bin/stalwart-cli apply --file "$plan" --json
    rm -f "$plan"
    printf '%s' "$relay_desired" > "$RELAY_STATE"
    echo "[mailhub] outbound relay: ${relay_desired%%|*}"
  fi

  if [ "$dns_desired" != "$dns_current" ]; then
    plan=/var/lib/stalwart/.mailhub-dns-plan.ndjson
    if [ -n "$DNS_SERVERS" ]; then
      servers_json=""
      index=0
      old_ifs="$IFS"
      IFS=','
      for entry in $DNS_SERVERS; do
        entry="$(printf '%s' "$entry" | tr -d ' ')"
        [ -n "$entry" ] || continue
        case "$entry" in
          *:*:*) address="$entry"; port=53 ;;           # IPv6，不支持附带端口
          *:*) address="${entry%:*}"; port="${entry##*:}" ;;
          *) address="$entry"; port=53 ;;
        esac
        [ "$index" -eq 0 ] || servers_json="${servers_json},"
        servers_json="${servers_json}\"${index}\":{\"protocol\":\"udp\",\"address\":\"$(json_escape "$address")\",\"port\":${port}}"
        index=$((index + 1))
      done
      IFS="$old_ifs"
      cat > "$plan" <<EOF_DNS
{"@type":"update","object":"DnsResolver","value":{"@type":"Custom","servers":{${servers_json}},"attempts":2,"concurrency":2,"enableEdns":true,"preserveIntermediates":true,"tcpOnError":true,"timeout":5000}}
EOF_DNS
    else
      cat > "$plan" <<'EOF_DNS'
{"@type":"update","object":"DnsResolver","value":{"@type":"System","attempts":2,"concurrency":2,"enableEdns":true,"preserveIntermediates":true,"tcpOnError":true,"timeout":5000}}
EOF_DNS
    fi
    /usr/local/bin/stalwart-cli apply --file "$plan" --json
    rm -f "$plan"
    printf '%s' "$dns_desired" > "$DNS_STATE"
    echo "[mailhub] DNS resolver: ${dns_desired}"
  fi

  stop_child "$child"
  unset STALWART_URL STALWART_USER STALWART_PASSWORD STALWART_RECOVERY_ADMIN STALWART_RECOVERY_MODE
}

automation_cli() {
  STALWART_URL=http://127.0.0.1:8080 STALWART_TOKEN="$(cat "$AUTOMATION_KEY_FILE" 2>/dev/null)" \
    /usr/local/bin/stalwart-cli "$@"
}

neutralize_collector_tags() {
  # 所有邮件都经 Collector 二次转投，下列标签对每封邮件都会命中，与邮件本身是否垃圾无关：
  #   HELO_NOT_FQDN / HELO_NORES_A_OR_MX  Collector 的 EHLO 名不是可解析公网域名
  #   FORGED_RECIPIENTS                   信封收件人是 admin@HUB_DOMAIN，To 是上游地址
  #   FORGED_RCVD_TRAIL                   Fetchmail 追加的 Received 头
  #   DMARC_NA                            2525 上禁用了 DMARC，“未检查”本身加分
  #   RCVD_NO_TLS_LAST                    Collector -> Stalwart 内部明文一跳
  # 只更新已存在的 SpamTag（首次启动由规则下载创建），不新建对象；分数已为 0 则跳过。
  [ -n "$NEUTRAL_TAGS" ] || return 0
  tags_json="$(automation_cli query SpamTag --json 2>/dev/null)" || return 1
  [ -n "$tags_json" ] || return 1
  changed=""
  old_ifs="$IFS"
  IFS=','
  for tag in $NEUTRAL_TAGS; do
    line="$(printf '%s\n' "$tags_json" | grep -F "\"tag\":\"${tag}\"" | head -1)"
    [ -n "$line" ] || continue
    case "$line" in *'"score":0.0'*|*'"score":0,'*|*'"score":0}'*) continue ;; esac
    id="$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    if automation_cli update SpamTag "$id" --field score=0 >/dev/null 2>&1; then
      changed="${changed} ${tag}"
    fi
  done
  IFS="$old_ifs"
  if [ -n "$changed" ]; then
    # SpamTag 写入存储后运行中的过滤器不会自动生效，必须 ReloadSettings（0.16.22 实测）。
    automation_cli create Action/ReloadSettings >/dev/null 2>&1 || \
      echo "[mailhub] warning: ReloadSettings failed; tag scores apply after restart" >&2
    echo "[mailhub] collector-only spam tags neutralized:${changed}"
  fi
  return 0
}

start_background_jobs() {
  # Stalwart 官方没有内置规则更新周期，这里在同一容器内后台定时提交
  # SpamFilterMaintenance/updateRules 任务，并在每次更新后重新确认 Collector 标签分数。
  (
    # 标签清零不等 RULES_UPDATE_DELAY：Stalwart 一就绪就执行，避免启动后最先进来的
    # 邮件仍按旧分数计分。首次部署时规则还在下载，最多等约 10 分钟 SpamTag 出现。
    i=0
    while [ "$i" -lt 120 ]; do
      automation_cli query SpamTag --json 2>/dev/null | grep -q '"tag":"HELO_NOT_FQDN"' && break
      i=$((i + 1))
      sleep 5
    done
    neutralize_collector_tags || echo "[mailhub] warning: failed to read spam tags with automation key" >&2

    [ "$RULES_UPDATE_HOURS" -gt 0 ] || exit 0
    sleep "$RULES_UPDATE_DELAY"
    while :; do
      if automation_cli create Task/SpamFilterMaintenance --field maintenanceType=updateRules >/dev/null 2>&1; then
        echo "[mailhub] spam rule update task submitted; next in ${RULES_UPDATE_HOURS}h"
        sleep 60
        neutralize_collector_tags || true
      else
        echo "[mailhub] warning: failed to submit spam rule update task; retry in ${RULES_UPDATE_HOURS}h" >&2
      fi
      sleep $((RULES_UPDATE_HOURS * 3600))
    done
  ) &
  if [ "$RULES_UPDATE_HOURS" -gt 0 ]; then
    echo "[mailhub] spam rule auto-update every ${RULES_UPDATE_HOURS}h (first run in ${RULES_UPDATE_DELAY}s)"
  else
    echo "[mailhub] spam rule auto-update disabled"
  fi
}

if [ ! -s "$CONFIG" ]; then
  start_bootstrap "$@"
fi

provision_once "$@"
reconcile_default_role_bindings "$@"
reconcile_oidc "$@"
reconcile_options "$@"

unset STALWART_RECOVERY_ADMIN STALWART_RECOVERY_MODE STALWART_RECOVERY_MODE_PORT STALWART_USER STALWART_PASSWORD STALWART_URL
start_background_jobs
exec /usr/local/bin/stalwart "$@"
