package store

import (
	"context"
	"time"
)

func (s *Store) CountCoachCallsSince(
	ctx context.Context, userID string, since time.Time,
) (int, error) {
	var count int
	err := s.pool.QueryRow(ctx, `
		SELECT count(*) FROM coach_usage WHERE user_id = $1::uuid AND created_at >= $2`,
		userID, since,
	).Scan(&count)
	return count, err
}

func (s *Store) InsertCoachUsage(
	ctx context.Context, userID, model string, inputTokens, outputTokens *int, status int,
) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO coach_usage (user_id, model, input_tokens, output_tokens, status)
		VALUES ($1::uuid, $2, $3, $4, $5)`,
		userID, model, inputTokens, outputTokens, status)
	return err
}
