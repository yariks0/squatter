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

See `.env.example`. Notable: `ANTHROPIC_API_KEY` (required for `/v1/coach`),
`RESEND_API_KEY` (empty ⇒ codes logged instead of emailed), `COACH_MODEL`,
`COACH_DAILY_LIMIT`, `TOKEN_TTL_DAYS`, `CODE_TTL_MINUTES`.

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

## Deploying (later)

Compose runs anywhere Docker does. Point `DATABASE_URL` at managed Postgres,
set the real `ANTHROPIC_API_KEY` and `RESEND_API_KEY` (with a DNS-verified
sending domain — the Resend sandbox only delivers to the account owner), and
put a TLS terminator in front. **Raise any reverse-proxy/LB idle timeout to
≥ 310 s** so the long coach call survives.
