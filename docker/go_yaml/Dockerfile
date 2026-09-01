FROM golang:1.23-bookworm AS build

WORKDIR /src
# internal/goyaml is a vendored copy of gopkg.in/yaml.v3 v3.0.1 plus one added
# file re-exporting its internal event stream, so the build needs no network
# and the reported version cannot drift from what is actually compiled in.
COPY go.mod go.sum ./
COPY emit.go ./
COPY internal ./internal

# Static so the runtime stage needs no libc beyond what it already has.
RUN CGO_ENABLED=0 GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o /emit .

FROM gcr.io/distroless/static-debian12
COPY --from=build /emit /emit
ENTRYPOINT []
CMD ["/emit"]
