# syntax=docker/dockerfile:1
ARG FETCHMAIL_VERSION=6.6.7
ARG ALPINE_VERSION=3.24.1

FROM alpine:${ALPINE_VERSION} AS fetchmail-build
ARG FETCHMAIL_VERSION
ARG FETCHMAIL_SHA256=bece8aaaa68e029eed9fd55fffd2adc7dd6cd5e9574d5bf92e2d9208bd97a881
RUN set -eux; \
    apk add --no-cache build-base curl openssl-dev ca-certificates tar xz; \
    archive=/tmp/fetchmail.tar.xz; \
    ok=0; \
    for url in \
      "https://sourceforge.net/projects/fetchmail/files/branch_6.6/fetchmail-${FETCHMAIL_VERSION}.tar.xz/download" \
      "https://netcologne.dl.sourceforge.net/project/fetchmail/branch_6.6/fetchmail-${FETCHMAIL_VERSION}.tar.xz" \
      "https://netactuate.dl.sourceforge.net/project/fetchmail/branch_6.6/fetchmail-${FETCHMAIL_VERSION}.tar.xz" \
      "https://nchc.dl.sourceforge.net/project/fetchmail/branch_6.6/fetchmail-${FETCHMAIL_VERSION}.tar.xz"; \
    do \
      echo "Trying Fetchmail source: ${url}"; \
      rm -f "${archive}"; \
      if curl -fL \
          --retry 4 --retry-delay 2 --retry-all-errors \
          --connect-timeout 20 --max-time 180 \
          -A 'mail-hub-builder/1.0' \
          "${url}" -o "${archive}" \
        && echo "${FETCHMAIL_SHA256}  ${archive}" | sha256sum -c -; \
      then \
        ok=1; \
        break; \
      fi; \
      echo "Fetchmail source failed or checksum mismatched; trying next mirror" >&2; \
    done; \
    test "${ok}" = 1; \
    mkdir /src; \
    tar -xJf "${archive}" -C /src --strip-components=1; \
    cd /src; \
    ./configure --prefix=/usr --disable-nls; \
    make -j"$(getconf _NPROCESSORS_ONLN)"; \
    make DESTDIR=/out install

FROM alpine:${ALPINE_VERSION}
# Alpine 点版本镜像里预装的 OpenSSL 运行库可能比当前 v3.24 仓库旧。
# Fetchmail 会拒绝加载比编译时头文件更旧的 OpenSSL 运行库。
# 因此这里显式使用 --upgrade，让 libssl/libcrypto 与上面 openssl-dev 的版本保持一致。
RUN apk add --no-cache --upgrade ca-certificates tzdata su-exec libssl3 libcrypto3 \
 && addgroup -S -g 10001 fetchmail \
 && adduser -S -D -h /home/fetchmail -u 10001 -G fetchmail -s /sbin/nologin fetchmail \
 && mkdir -p /data /accounts /home/fetchmail \
 && chown -R 10001:10001 /data /home/fetchmail
COPY --from=fetchmail-build /out/usr/bin/fetchmail /usr/bin/fetchmail
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
 && apk info -v libssl3 libcrypto3 \
 && /usr/bin/fetchmail --version | head -n 2
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
