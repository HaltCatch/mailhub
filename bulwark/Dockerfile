# syntax=docker/dockerfile:1
ARG BULWARK_VERSION=1.9.2
FROM ghcr.io/bulwarkmail/webmail:${BULWARK_VERSION}
USER root
RUN apk add --no-cache su-exec
COPY entrypoint.sh /usr/local/bin/mailhub-bulwark-entrypoint.sh
RUN chmod 0755 /usr/local/bin/mailhub-bulwark-entrypoint.sh
USER root
ENTRYPOINT ["/usr/local/bin/mailhub-bulwark-entrypoint.sh"]
CMD ["node", "server.js"]
