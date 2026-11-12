FROM alpine:3.18

RUN apk add --no-cache git git-lfs openssh-client && \
  git lfs install

ADD entrypoint.sh /bin/
RUN chmod +x /bin/entrypoint.sh

ENTRYPOINT ["/bin/entrypoint.sh"] 