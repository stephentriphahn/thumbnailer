FROM alpine:3.24.4

RUN apk add --no-cache kubectl
COPY publish.sh /usr/local/bin/publish.sh
RUN chmod +x /usr/local/bin/publish.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/publish.sh"]