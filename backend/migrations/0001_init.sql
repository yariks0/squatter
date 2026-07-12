-- +goose Up
CREATE TABLE users (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email      text NOT NULL UNIQUE, -- stored lowercased/trimmed
    created_at timestamptz NOT NULL DEFAULT now()
);

-- One-time login codes, keyed by email (users are created lazily on the
-- first successful verify, so unknown emails behave identically here).
CREATE TABLE auth_codes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL,
    code_hash   bytea NOT NULL, -- HMAC-SHA256(salt, code)
    salt        bytea NOT NULL,
    expires_at  timestamptz NOT NULL,
    attempts    int NOT NULL DEFAULT 0,
    consumed_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX auth_codes_email_created ON auth_codes (email, created_at DESC);

-- Auth sessions: opaque bearer tokens, only their SHA-256 at rest.
CREATE TABLE sessions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   bytea NOT NULL UNIQUE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL
);
CREATE INDEX sessions_user ON sessions (user_id);

-- Workout session summaries (the compact, portable slice of an analysis —
-- the heavy JointSeries/video/depth data never leaves the device).
CREATE TABLE workout_sessions (
    id         uuid PRIMARY KEY, -- client-supplied: the recording's UUID
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date       timestamptz NOT NULL,
    activity   text NOT NULL,
    score      int NOT NULL,
    rep_count  int NOT NULL,
    used_lidar boolean NOT NULL,
    weight_kg  double precision,
    reps       jsonb NOT NULL DEFAULT '[]', -- compact RepMetrics array, opaque
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX workout_sessions_user_date ON workout_sessions (user_id, date DESC);

-- Whole-document profile stores; payload schemas evolve in Swift
-- (optional-fields law), the server never looks inside.
CREATE TABLE body_profiles (
    user_id    uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    payload    jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE plate_catalogs (
    user_id    uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    payload    jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Per-call coach accounting: drives the daily quota and cost visibility.
CREATE TABLE coach_usage (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    model         text NOT NULL,
    input_tokens  int,
    output_tokens int,
    status        int NOT NULL
);
CREATE INDEX coach_usage_user_created ON coach_usage (user_id, created_at);

-- +goose Down
DROP TABLE coach_usage;
DROP TABLE plate_catalogs;
DROP TABLE body_profiles;
DROP TABLE workout_sessions;
DROP TABLE sessions;
DROP TABLE auth_codes;
DROP TABLE users;
