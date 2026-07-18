.PHONY: run test compose-up compose-down psql tidy migrate-new \
	prod-up prod-down prod-restart prod-logs prod-ps prod-psql prod-backup

# Production compose always needs --env-file (the ${...} in the prod compose
# file resolve from it) and -f. Going through these targets means never
# forgetting either.
PROD := docker compose --env-file .env.prod -f docker-compose.prod.yml

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

# --- Production (run these ON the droplet) -----------------------------------
# Rebuilds the image from the working tree and rolls the stack. `git pull &&
# make prod-up` is the whole deploy; the API self-migrates on boot.
prod-up: .env.prod
	$(PROD) up -d --build

prod-down:
	$(PROD) down

# Compose reads .env.prod only at container-create time — edited secrets need
# this, not `restart`.
prod-restart: .env.prod
	$(PROD) up -d --force-recreate

prod-logs:
	$(PROD) logs -f --tail=100

prod-ps:
	$(PROD) ps

prod-psql:
	$(PROD) exec db psql -U squatter -d squatter

# Gzipped dump to ./backups (gitignored). Point cron at this.
prod-backup:
	@mkdir -p backups
	@f="backups/squatter-$$(date -u +%Y%m%dT%H%M%SZ).sql.gz"; \
	$(PROD) exec -T db pg_dump -U squatter -d squatter | gzip > $$f; \
	echo "wrote $$f"

.env.prod:
	@echo "apps/backend/.env.prod is missing."
	@echo "  cp .env.prod.example .env.prod && chmod 600 .env.prod   # then fill it in"
	@exit 1

# make migrate-new NAME=add_something
migrate-new:
	@test -n "$(NAME)" || (echo "NAME is required" && exit 1)
	@n=$$(printf '%04d' $$(( $$(ls migrations/*.sql | wc -l | tr -d ' ') + 1 ))); \
	f="migrations/$${n}_$(NAME).sql"; \
	printf -- "-- +goose Up\n\n-- +goose Down\n" > $$f; \
	echo "created $$f"
