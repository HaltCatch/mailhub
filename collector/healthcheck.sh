#!/bin/sh
set -eu
[ -f "${DATA_DIR:-/data}/.healthy" ]
pgrep fetchmail >/dev/null 2>&1 || {
  # 没有激活的账号配置也是允许的状态，此时 Collector 保持空闲并视为健康。
  active="$(find "${ACCOUNTS_DIR:-/accounts}" -maxdepth 1 -type f -name '*.env' ! -name '*.example.env' ! -name '*.disabled.env' 2>/dev/null | head -n 1 || true)"
  [ -z "$active" ]
}
