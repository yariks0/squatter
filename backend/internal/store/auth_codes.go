package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

type AuthCode struct {
	ID        int64
	Email     string
	CodeHash  []byte
	Salt      []byte
	ExpiresAt time.Time
	Attempts  int
	CreatedAt time.Time
}

func (s *Store) InsertAuthCode(
	ctx context.Context, email string, codeHash, salt []byte, expiresAt time.Time,
) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO auth_codes (email, code_hash, salt, expires_at)
		VALUES ($1, $2, $3, $4)`,
		email, codeHash, salt, expiresAt)
	return err
}

// LatestAuthCode returns the newest live (unconsumed, unexpired) code for
// the email; nil when there is none.
func (s *Store) LatestAuthCode(ctx context.Context, email string, now time.Time) (*AuthCode, error) {
	var code AuthCode
	err := s.pool.QueryRow(ctx, `
		SELECT id, email, code_hash, salt, expires_at, attempts, created_at
		FROM auth_codes
		WHERE email = $1 AND consumed_at IS NULL AND expires_at > $2
		ORDER BY created_at DESC LIMIT 1`,
		email, now,
	).Scan(&code.ID, &code.Email, &code.CodeHash, &code.Salt,
		&code.ExpiresAt, &code.Attempts, &code.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &code, nil
}

// NewestCodeCreatedAt drives the resend cooldown; zero time when the email
// has never requested a code.
func (s *Store) NewestCodeCreatedAt(ctx context.Context, email string) (time.Time, error) {
	var created time.Time
	err := s.pool.QueryRow(ctx, `
		SELECT created_at FROM auth_codes
		WHERE email = $1 ORDER BY created_at DESC LIMIT 1`,
		email,
	).Scan(&created)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, nil
	}
	return created, err
}

func (s *Store) CountCodesSince(ctx context.Context, email string, since time.Time) (int, error) {
	var count int
	err := s.pool.QueryRow(ctx, `
		SELECT count(*) FROM auth_codes WHERE email = $1 AND created_at >= $2`,
		email, since,
	).Scan(&count)
	return count, err
}

// IncrementAttempts bumps the guess counter before the comparison (so
// parallel guesses can't share one attempt) and returns the new count.
func (s *Store) IncrementAttempts(ctx context.Context, id int64) (int, error) {
	var attempts int
	err := s.pool.QueryRow(ctx, `
		UPDATE auth_codes SET attempts = attempts + 1 WHERE id = $1
		RETURNING attempts`,
		id,
	).Scan(&attempts)
	return attempts, err
}

// ConsumeAuthCode marks the winning code used and deletes every other
// outstanding code for the email — one successful login burns them all.
func (s *Store) ConsumeAuthCode(ctx context.Context, id int64, email string, now time.Time) error {
	batch := &pgx.Batch{}
	batch.Queue(`UPDATE auth_codes SET consumed_at = $1 WHERE id = $2`, now, id)
	batch.Queue(`DELETE FROM auth_codes WHERE email = $1 AND id <> $2`, email, id)
	return s.pool.SendBatch(ctx, batch).Close()
}
