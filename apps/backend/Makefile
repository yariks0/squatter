.PHONY: run test compose-up compose-down psql tidy migrate-new

# Local API against the compose Postgres (start `make compose-up` first, or
# just the db: `docker compose up -d db`).
run:
	go run ./cmd/api

test:
	go test ./...

compose-up:
	docker compose up --build -d

compose-down:
	docker compose down

psql:
	docker compose exec db psql -U squatter -d squatter

tidy:
	go mod tidy

# make migrate-new NAME=add_something
migrate-new:
	@test -n "$(NAME)" || (echo "NAME is required" && exit 1)
	@n=$$(printf '%04d' $$(( $$(ls migrations/*.sql | wc -l | tr -d ' ') + 1 ))); \
	f="migrations/$${n}_$(NAME).sql"; \
	printf -- "-- +goose Up\n\n-- +goose Down\n" > $$f; \
	echo "created $$f"
