#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

fail=0
say() { printf '%s\n' "$*"; }
err() { printf '错误：%s\n' "$*" >&2; fail=1; }

[ -f .env ] || err '缺少 .env，请先执行：cp .env.example .env'
if [ -f .env ]; then
  grep -Eq '(^|=)CHANGE_ME' .env && err '.env 中仍存在 CHANGE_ME 占位值' || true
  data_root="$(sed -n 's/^DATA_ROOT=//p' .env | tail -1)"
  [ -n "$data_root" ] || err '.env 中缺少 DATA_ROOT'

  oidc_enabled="$(sed -n 's/^MAIL_HUB_OIDC_ENABLED=//p' .env | tail -1)"
  if [ "$oidc_enabled" = "true" ]; then
    for key in MAIL_HUB_OIDC_ISSUER_URL MAIL_HUB_OIDC_CLIENT_ID MAIL_HUB_OIDC_CLIENT_SECRET MAIL_HUB_OIDC_USERNAME_CLAIM; do
      value="$(sed -n "s/^${key}=//p" .env | tail -1)"
      [ -n "$value" ] || err "OIDC 已开启，但 .env 缺少 ${key}"
      case "$value" in CHANGE_ME*) err "OIDC 已开启，但 ${key} 仍是占位值" ;; esac
    done
    issuer="$(sed -n 's/^MAIL_HUB_OIDC_ISSUER_URL=//p' .env | tail -1)"
    case "$issuer" in https://*) ;; *) err 'MAIL_HUB_OIDC_ISSUER_URL 应使用 HTTPS issuer URL' ;; esac
  fi
fi

active=0
for f in accounts/*.env; do
  [ -f "$f" ] || continue
  case "$f" in *.example.env|*.disabled.env) continue ;; esac
  active=$((active + 1))
  grep -q 'CHANGE_ME' "$f" && err "$f 中仍存在 CHANGE_ME 占位值" || true
done
[ "$active" -gt 0 ] || say '警告：当前没有激活的 accounts/*.env，Collector 会保持空闲。'

grep -Eq '^volumes:' compose.yaml && err '检测到顶层 Docker named volumes；当前设计应使用固定宿主机 bind mount' || true
grep -Eq '^[[:space:]]+bootstrap:' compose.yaml && err '检测到旧 bootstrap sidecar；当前版本不应存在该服务' || true
grep -q 'source: ${DATA_ROOT:-/mnt/data/docker/mail-hub}/stalwart/etc' compose.yaml || err '缺少 Stalwart 固定 DATA_ROOT bind mount'
grep -q 'JMAP_SERVER_URL: ${STALWART_PUBLIC_URL' compose.yaml || err 'Bulwark JMAP 地址必须使用公开的 STALWART_PUBLIC_URL'
grep -q '\${STALWART_HTTP_HOST_PORT:-8443}:8080' compose.yaml || err '缺少 Stalwart 8443 -> 8080 HTTP 映射'
grep -q 'FETCH_ALL_ON_FIRST_RUN: ${COLLECTOR_FETCH_ALL_ON_FIRST_RUN:-false}' compose.yaml || err '首次历史导入开关缺失或默认值不是 false'
grep -q 'enableSpamFilter.*local_port.*COLLECTOR_PORT.*true' stalwart/entrypoint.sh || err 'Collector 2525 未显式启用 Stalwart Spam Filter'
grep -q '"object":"SpamSettings".*"enable":true.*"scoreSpam":5' stalwart/entrypoint.sh || err '缺少 Stalwart SpamSettings 声明式配置'
grep -q 'OAUTH_ENABLED: ${MAIL_HUB_OIDC_ENABLED:-false}' compose.yaml || err 'Bulwark OIDC 开关未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_ENABLED: ${MAIL_HUB_OIDC_ENABLED:-false}' compose.yaml || err 'Stalwart OIDC 开关未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_ISSUER_URL: ${MAIL_HUB_OIDC_ISSUER_URL:-}' compose.yaml || err 'Stalwart OIDC issuer 未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_CLIENT_ID: ${MAIL_HUB_OIDC_CLIENT_ID:-}' compose.yaml || err 'Stalwart OIDC Client ID 未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_USERNAME_CLAIM: ${MAIL_HUB_OIDC_USERNAME_CLAIM:-email}' compose.yaml || err 'Stalwart OIDC username claim 未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_USERNAME_DOMAIN: ${MAIL_HUB_OIDC_USERNAME_DOMAIN:-}' compose.yaml || err 'Stalwart OIDC username domain 未映射到 Compose'
grep -q 'MAIL_HUB_OIDC_NAME_CLAIM: ${MAIL_HUB_OIDC_NAME_CLAIM:-name}' compose.yaml || err 'Stalwart OIDC name claim 未映射到 Compose'
grep -q '"@type":"Oidc"' stalwart/entrypoint.sh || err 'Stalwart OIDC Directory 声明式配置缺失'
project_version="$(cat VERSION 2>/dev/null || true)"
version_labels="$(grep -Ec "com\.cyberdeck\.mailhub\.version: \"?${project_version}\"?\$" compose.yaml || true)"
[ -n "$project_version" ] && [ "$version_labels" -eq 4 ] || err 'Compose 的四个服务版本标签必须与 VERSION 一致'
if grep -Eq ':[ ]*(465|587|993|4190)([^0-9]|$)' compose.yaml; then
  err '当前 HTTP-only profile 不应发布 465/587/993/4190 直连端口'
fi

if command -v docker >/dev/null 2>&1; then
  docker compose config >/dev/null || err 'docker compose config 校验失败'
else
  say '警告：当前环境没有 docker，跳过 Compose 渲染校验。'
fi

[ "$fail" -eq 0 ] || exit 1
say 'MailHub doctor：OK'
