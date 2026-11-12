#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

TIMEOUT="${MAILHUB_REHEARSAL_TIMEOUT:-1800}"

if [ "${1:-}" != "--yes" ]; then
  echo '这是破坏性冷启动演练：会清空整个 MailHub DATA_ROOT。'
  echo '项目源码、.env 和 accounts/*.env 会保留。'
  echo '确认后重新执行：./scripts/rehearse-cold-start.sh --yes'
  exit 2
fi

./scripts/doctor.sh
./scripts/reset-data.sh --yes

echo '===== 无缓存构建 ====='
docker compose build --pull --no-cache

echo '===== 冷启动 ====='
docker compose up -d

start="$(date +%s)"
while :; do
  healthy=0
  for service in stalwart bulwark collector; do
    cid="$(docker compose ps -q "$service" 2>/dev/null || true)"
    [ -n "$cid" ] || continue
    status="$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = healthy ] && healthy=$((healthy + 1))
  done
  printf '健康服务：%s/3\n' "$healthy"
  [ "$healthy" -eq 3 ] && break
  now="$(date +%s)"
  [ $((now - start)) -lt "$TIMEOUT" ] || {
    echo '错误：等待服务健康状态超时'
    docker compose ps -a
    exit 1
  }
  sleep 5
done

# 默认关闭历史全量导入。只有全局或单账号显式开启时才等待 marker。
global_fetch="$(sed -n 's/^COLLECTOR_FETCH_ALL_ON_FIRST_RUN=//p' .env 2>/dev/null | tail -1)"
global_fetch="${global_fetch:-false}"
expected=0
for f in accounts/*.env; do
  [ -f "$f" ] || continue
  case "$f" in *.example.env|*.disabled.env) continue ;; esac
  override="$(sed -n 's/^FETCH_ALL_ON_FIRST_RUN=//p' "$f" | tail -1)"
  value="${override:-$global_fetch}"
  case "$value" in
    true|1|yes|on) expected=$((expected + 1)) ;;
  esac
done

if [ "$expected" -gt 0 ]; then
  echo "===== 等待显式开启的历史导入：0/$expected ====="
  while :; do
    complete="$(docker exec mailhub-collector sh -lc 'n=0; for f in /data/*/.initial-fetchall-complete; do [ -f "$f" ] && n=$((n+1)); done; echo "$n"' 2>/dev/null || echo 0)"
    printf '历史导入完成：%s/%s\n' "$complete" "$expected"
    [ "$complete" -ge "$expected" ] && break
    now="$(date +%s)"
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
      echo '警告：等待历史导入超时；四个服务已健康，但部分可选全量导入仍在运行或失败。'
      break
    fi
    sleep 10
  done
else
  echo '===== 历史全量导入默认关闭，跳过 marker 等待 ====='
fi

./scripts/health.sh
