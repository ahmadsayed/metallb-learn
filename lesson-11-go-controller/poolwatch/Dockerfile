# The lab builds a static binary on the host and copies it in, which keeps the
# image tiny and the build fast:
#
#   CGO_ENABLED=0 go build -o poolwatch .
#   docker build -t poolwatch:lab .
#
# A multi-stage build (golang:1.25 → distroless) is the production equivalent —
# see the lesson README for that variant.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY poolwatch /usr/local/bin/poolwatch
# Run as nobody: the controller only reads the API and writes metrics.
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/poolwatch"]
