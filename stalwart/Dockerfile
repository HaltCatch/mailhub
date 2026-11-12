# syntax=docker/dockerfile:1
ARG STALWART_VERSION=v0.16.21
ARG STALWART_CLI_VERSION=1.0.12
FROM ghcr.io/stalwartlabs/cli:${STALWART_CLI_VERSION} AS cli
FROM stalwartlabs/stalwart:${STALWART_VERSION}
USER root
# Stalwart 上游以 UID/GID 2000 运行。Docker 自动创建的 bind mount 目录归 root 所有，
# 因此包装入口需要一个轻量降权工具：先初始化挂载根目录，再回到上游非 root 身份。
RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends gosu; \
      rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
      apk add --no-cache su-exec; \
    else \
      echo 'No supported package manager found for privilege-drop helper' >&2; \
      exit 1; \
    fi
COPY --from=cli /usr/local/bin/stalwart-cli /usr/local/bin/stalwart-cli
COPY entrypoint.sh /usr/local/bin/mail-hub-entrypoint.sh
RUN chmod 0755 /usr/local/bin/stalwart-cli /usr/local/bin/mail-hub-entrypoint.sh
USER root
ENTRYPOINT ["/usr/local/bin/mail-hub-entrypoint.sh"]
CMD ["--config", "/etc/stalwart/config.json"]
