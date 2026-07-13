package store

import (
	"context"
	"time"
)

type User struct {
	ID        string
	Email     string
	CreatedAt time.Time
}

// UpsertUser creates the user on first successful login; the no-op update
// makes RETURNING work for existing rows.
func (s *Store) UpsertUser(ctx context.Context, email string) (User, error) {
	var user User
	err := s.pool.QueryRow(ctx, `
		INSERT INTO users (email) VALUES ($1)
		ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
		RETURNING id::text, email, created_at`,
		email,
	).Scan(&user.ID, &user.Email, &user.CreatedAt)
	return user, err
}
