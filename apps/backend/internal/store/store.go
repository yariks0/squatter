// Package store is the Postgres layer: pgx, hand-written SQL, one file per
// aggregate. No ORM — ~25 queries total, and the client-owned payloads
// (rep metrics, profile documents) are opaque JSONB the server never
// inspects.
package store

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}
