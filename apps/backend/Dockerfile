# Build the API as a static binary, then ship it on distroless (no shell,
# small surface).
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /api ./cmd/api

FROM gcr.io/distroless/static-debian12
COPY --from=build /api /api
EXPOSE 8080
ENTRYPOINT ["/api"]
