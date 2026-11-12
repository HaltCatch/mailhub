#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

DATA_ROOT="${DATA_ROOT:-}"
if [ -z "$DATA_ROOT" ] && [ -f .env ]; then
  DATA_ROOT="$(sed -n 's/^DATA_ROOT=//p' .env | tail -1)"
fi
DATA_ROOT="${DATA_ROOT:-/mnt/data/docker/mail-hub}"

if [ "${1:-}" != "--yes" ]; then
  echo "该操作会删除 MailHub 的全部运行数据：$DATA_ROOT"
  echo '不会删除项目源码、.env 或 accounts/*.env。'
  printf '请输入 RESET-MAILHUB 确认：'
  read answer
  [ "$answer" = "RESET-MAILHUB" ] || { echo '已取消。'; exit 1; }
fi

docker compose down --remove-orphans

# 使用临时容器以 root 删除数据，避免宿主机目录所有权影响重置操作。
docker run --rm \
  -v "$DATA_ROOT:/mailhub" \
  alpine:3.24.1 \
  sh -ec 'find /mailhub -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'

echo "已清空 MailHub 运行数据：$DATA_ROOT"
echo '.env 和 accounts/*.env 保持不变。'
echo '下一步：docker compose up -d'
