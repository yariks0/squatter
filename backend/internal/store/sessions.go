package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

type Session struct {
	ID         string
	UserID     string
	LastUsedAt time.Time
	ExpiresAt  time.Time
}

func (s *Store) InsertSession(
	ctx context.Context, userID string, tokenHash []byte, expiresAt time.Time,
) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO sessions (user_id, token_hash, expires_at)
		VALUES ($1::uuid, $2, $3)`,
		userID, tokenHash, expiresAt)
	return err
}

// SessionByTokenHash resolves a live bearer token to its session and user;
// nils when the token is unknown or expired.
func (s *Store) SessionByTokenHash(
	ctx context.Context, tokenHash []byte, now time.Time,
) (*Session, *User, error) {
	var session Session
	var user User
	err := s.pool.QueryRow(ctx, `
		SELECT s.id::text, s.user_id::text, s.last_used_at, s.expires_at,
		       u.id::text, u.email, u.created_at
		FROM sessions s JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1 AND s.expires_at > $2`,
		tokenHash, now,
	).Scan(&session.ID, &session.UserID, &session.LastUsedAt, &session.ExpiresAt,
		&user.ID, &user.Email, &user.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	return &session, &user, nil
}

// TouchSession slides the expiry forward; callers throttle this to at most
// one write per day (see httpapi auth middleware).
func (s *Store) TouchSession(ctx context.Context, id string, now, expiresAt time.Time) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE sessions SET last_used_at = $1, expires_at = $2 WHERE id = $3::uuid`,
		now, expiresAt, id)
	return err
}

func (s *Store) DeleteSessionByTokenHash(ctx context.Context, tokenHash []byte) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash)
	return err
}
