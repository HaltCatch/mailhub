#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

echo '===== Docker Compose 状态 ====='
docker compose ps

echo
echo '===== Stalwart 日志 ====='
docker compose logs --tail=50 stalwart 2>/dev/null || true

echo
echo '===== Collector 日志 ====='
docker compose logs --tail=100 collector 2>/dev/null || true

echo
echo '===== 可选历史导入 marker ====='
docker exec mailhub-collector sh -lc 'for f in /data/*/.initial-fetchall-complete; do [ -f "$f" ] || continue; echo "${f%/.initial-fetchall-complete}: complete"; done' 2>/dev/null || true

echo
echo '===== Bulwark 日志 ====='
docker compose logs --tail=30 bulwark 2>/dev/null || true


echo
echo '===== HTTP 健康检查 ====='
curl -fsS -o /dev/null -w 'Stalwart 7080：HTTP %{http_code}\n' http://127.0.0.1:${STALWART_BOOTSTRAP_HOST_PORT:-7080}/healthz/live 2>/dev/null || true
curl -fsS -o /dev/null -w 'Stalwart 8443：HTTP %{http_code}\n' http://127.0.0.1:${STALWART_HTTP_HOST_PORT:-8443}/healthz/live 2>/dev/null || true
