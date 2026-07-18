# Squatter backend

Go API for the Squatter iOS app: passwordless email auth, an Anthropic coach
proxy (holds the API key server-side), and profile/progress sync. Postgres 18
for storage, Docker Compose for local/MVP deployment.

Lives at `apps/backend/` in the monorepo — run the commands below from there
(or their `make backend-*` / `make compose-*` wrappers from the repo root).

## Quick start (dev — no email account needed)

```sh
cp .env.example .env          # leave RESEND_API_KEY empty → codes go to the log
make compose-up               # postgres 18 + api, self-migrates on boot
curl localhost:8080/healthz   # {"status":"ok"}
```

> Upgrading from an older Postgres image? A named `pgdata` volume created by
> an earlier major version won't start under Postgres 18. Dev data is
> disposable, so reset it: `docker compose down -v && make compose-up`
> (goose re-applies every migration on the fresh volume).

Log in from the command line:

```sh
curl -sX POST localhost:8080/v1/auth/request-code \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}'
docker compose logs api | grep 'login code'   # read the 6-digit code

TOKEN=$(curl -sX POST localhost:8080/v1/auth/verify \
  -H 'content-type: application/json' \
  -d '{"email":"you@example.com","code":"123456"}' | jq -r .token)

curl -s localhost:8080/v1/me -H "authorization: Bearer $TOKEN"
```

`make run` runs the API on the host against the compose Postgres (start it
with `docker compose up -d db` first); `make test` runs unit tests; `make
psql` opens a shell on the database.

## Endpoints (all JSON, snake_case, `/v1`)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/v1/auth/request-code` | — | email a 6-digit code (204 always; 429 rate-limited) |
| POST | `/v1/auth/verify` | — | code → `{token, user}` |
| POST | `/v1/auth/logout` | bearer | revoke this token |
| GET | `/v1/me` | bearer | current user |
| POST | `/v1/coach` | bearer | proxy an Anthropic Messages request (see below) |
| GET/PUT | `/v1/profile/body` | bearer | body-geometry document |
| GET/PUT | `/v1/profile/plates` | bearer | plate-catalog document |
| PUT | `/v1/sessions/{id}` | bearer | upsert a workout summary (id = recording UUID) |
| GET | `/v1/sessions[?since=RFC3339]` | bearer | list summaries |
| DELETE | `/v1/sessions/{id}` | bearer | delete a summary |

### Coach proxy

The app builds the full Anthropic `/v1/messages` body (its prompt embeds live
analysis thresholds, so keeping that in Swift avoids a rotting duplicate) and
POSTs it here. The server validates shape/size, **pins the model** to
`COACH_MODEL`, enforces `COACH_DAILY_LIMIT` per user, injects
`ANTHROPIC_API_KEY`, and returns Anthropic's response verbatim.

## Config

See `.env.example` (dev) and `.env.prod.example` (production secrets — the
deploy section below). Notable: `ANTHROPIC_API_KEY` (required for `/v1/coach`),
`RESEND_API_KEY` (empty ⇒ codes logged instead of emailed), `COACH_MODEL`,
`COACH_DAILY_LIMIT`, `TOKEN_TTL_DAYS`, `CODE_TTL_MINUTES`, `TRUST_PROXY`
(`true` only when a reverse proxy owns the edge).

## Auth model

6-digit codes: HMAC-SHA256 with a per-code salt at rest, 10-minute expiry,
5-attempt cap, single-use, 60 s resend cooldown + 5/hour per email + 10/min
per IP. Sessions are opaque bearer tokens (only their SHA-256 stored) with a
sliding 90-day expiry. Users are created lazily on first successful verify.

## Storage tests

Tests that touch Postgres read `TEST_DATABASE_URL` and skip when it is unset:

```sh
TEST_DATABASE_URL=postgres://squatter:squatter@localhost:5432/squatter?sslmode=disable make test
```

## Deploying to a Docker VM

`docker-compose.prod.yml` runs the whole stack on one droplet: Caddy
terminates TLS on 80/443 and proxies to the API; the API and Postgres are
reachable **only** on the internal compose network. It is a separate file from
the dev `docker-compose.yml`, not an override — dev publishes ports and
hardcodes a password, and both are wrong in production.

### Prerequisites

- A domain (say `api.example.com`) with an **A record pointing at the
  droplet's public IP**. Caddy issues the certificate on first boot, and that
  fails if DNS isn't live yet.
- Ports 22, 80 and 443 open. In DigitalOcean use a **Cloud Firewall**, not
  just `ufw` — Docker writes its own iptables rules and punches through `ufw`.
- A Resend account with a DNS-verified sending domain.

### First deploy

```sh
ssh root@<droplet-ip>
git clone <repo-url> /opt/squatter
cd /opt/squatter/apps/backend

cp .env.prod.example .env.prod
chmod 600 .env.prod      # it holds every credential
vi .env.prod             # fill in — see "Secrets" below

make prod-up             # builds the image on the VM, starts db + api + caddy
curl https://api.example.com/healthz    # {"status":"ok"}
```

The API self-migrates on boot, so there is no migrate step. Certificate
issuance takes a few seconds on first boot; `make prod-logs` shows it.

### Secrets

**All secrets live in one file: `apps/backend/.env.prod`, on the droplet
only.** It is gitignored and `.dockerignore`d, so it can't reach the repo or
the image. Copy it from `.env.prod.example`, which documents every key.

| Variable | Where to get it |
|---|---|
| `POSTGRES_PASSWORD` | generate once: `openssl rand -hex 32` |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API keys |
| `RESEND_API_KEY` | resend.com → API keys |
| `EMAIL_FROM` | a domain verified in Resend |
| `API_DOMAIN`, `ACME_EMAIL` | your domain / your email |

Two things that bite:

- **Never leave `RESEND_API_KEY` empty in prod.** Empty is the *dev*
  behaviour — it silently prints login codes to the server log, so anyone who
  can read logs can log in as anyone.
- **`POSTGRES_PASSWORD` is only applied when the `pgdata` volume is first
  created.** Changing it later updates the API's connection string but not the
  database, and the API stops being able to connect. To rotate it, change it
  in the running database (`make prod-psql` → `ALTER USER squatter WITH
  PASSWORD '…';`) and in `.env.prod`, then `make prod-restart`.

`make prod-restart` (not `restart`) is what re-reads `.env.prod` — compose
only reads it when it creates containers.

### Day-to-day

```sh
make prod-up        # deploy: rebuild the image + roll the stack
make prod-logs      # follow all three services
make prod-ps        # health of each container
make prod-psql      # psql shell on the database
make prod-backup    # gzipped pg_dump into ./backups (gitignored)
make prod-down      # stop (volumes survive)
```

Deploying a change is `git pull && make prod-up`.

Nightly backup off the box — `pg_dump` to a local file protects against a bad
migration, not a dead droplet, so copy it somewhere else:

```sh
# crontab -e
0 3 * * * cd /opt/squatter/apps/backend && make prod-backup && \
  find backups -name '*.sql.gz' -mtime +14 -delete
```

### Notes on the setup

- **Long coach calls survive**: Caddy's `response_header_timeout` is 320 s,
  above the API's own 310 s deadline for `/v1/coach`, so the API is always the
  one that decides to give up.
- **Rate limiting behind the proxy**: the API's per-IP limiter would bucket
  every caller under Caddy's container address, so prod sets `TRUST_PROXY=true`
  and the limiter reads the last `X-Forwarded-For` entry (the hop Caddy
  appends, which a client cannot forge). Do **not** set `TRUST_PROXY` on a
  directly-exposed server — it would let anyone forge their bucket key.
- **Postgres is not published.** Reach it with `make prod-psql`, or over an
  SSH tunnel — never by adding a `ports:` entry.
- Logs are capped (10 MB × 3 per service); unbounded Docker logs otherwise
  fill the disk and take Postgres down with them.
- Caddy's certificates live in the `caddy_data` volume. Don't delete it
  casually — re-issuing on every restart hits Let's Encrypt's rate limits.

### iOS app

Point the Release `BackendConfig` base URL at `https://api.example.com`. No ATS
exception is needed — Caddy serves a real certificate.
