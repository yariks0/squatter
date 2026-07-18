# Build the API as a static binary, then ship it on distroless (no shell,
# no package manager, tiny surface). Same image for dev and prod.
FROM golang:1.25-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
# -trimpath drops build-host paths from panics; -s -w drops the symbol table
# and DWARF (~30% smaller, and this binary is never debugged in place).
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /api ./cmd/api

# :nonroot runs as uid 65532 — the API writes nothing to disk, so it needs no
# write access anywhere. The base ships ca-certificates (Resend + Anthropic
# are HTTPS) and tzdata.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /api /api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/api"]
