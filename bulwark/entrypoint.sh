#!/bin/sh
set -eu

# bind mount 会覆盖上游镜像里原本创建的目录。这里只创建实际需要的挂载根目录，
# 然后把所有权交给 Bulwark 上游使用的 UID 1001。
mkdir -p /app/data/settings /app/data/admin /app/data/admin-state /app/data/telemetry
chown 1001:1001 \
  /app/data \
  /app/data/settings \
  /app/data/admin \
  /app/data/admin-state \
  /app/data/telemetry
chmod 0750 \
  /app/data \
  /app/data/settings \
  /app/data/admin \
  /app/data/admin-state \
  /app/data/telemetry

exec su-exec 1001:1001 "$@"
