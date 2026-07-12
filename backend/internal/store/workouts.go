package store

import (
	"context"
	"encoding/json"
	"time"
)

type WorkoutSession struct {
	ID        string          `json:"id"`
	Date      time.Time       `json:"date"`
	Activity  string          `json:"activity"`
	Score     int             `json:"score"`
	RepCount  int             `json:"rep_count"`
	UsedLiDAR bool            `json:"used_lidar"`
	WeightKg  *float64        `json:"weight_kg,omitempty"`
	Reps      json.RawMessage `json:"reps"`
	UpdatedAt time.Time       `json:"updated_at"`
}

// UpsertWorkout is idempotent on the client-generated recording UUID, so
// retried pushes and re-analyses converge on one row.
func (s *Store) UpsertWorkout(ctx context.Context, userID string, w WorkoutSession) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO workout_sessions
			(id, user_id, date, activity, score, rep_count, used_lidar, weight_kg, reps)
		VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (id) DO UPDATE SET
			date = EXCLUDED.date, activity = EXCLUDED.activity,
			score = EXCLUDED.score, rep_count = EXCLUDED.rep_count,
			used_lidar = EXCLUDED.used_lidar, weight_kg = EXCLUDED.weight_kg,
			reps = EXCLUDED.reps, updated_at = now()
		WHERE workout_sessions.user_id = EXCLUDED.user_id`,
		w.ID, userID, w.Date, w.Activity, w.Score, w.RepCount,
		w.UsedLiDAR, w.WeightKg, w.Reps)
	return err
}

func (s *Store) ListWorkouts(
	ctx context.Context, userID string, since *time.Time,
) ([]WorkoutSession, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id::text, date, activity, score, rep_count, used_lidar,
		       weight_kg, reps, updated_at
		FROM workout_sessions
		WHERE user_id = $1::uuid AND ($2::timestamptz IS NULL OR updated_at >= $2)
		ORDER BY date DESC`,
		userID, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sessions := []WorkoutSession{}
	for rows.Next() {
		var w WorkoutSession
		if err := rows.Scan(&w.ID, &w.Date, &w.Activity, &w.Score, &w.RepCount,
			&w.UsedLiDAR, &w.WeightKg, &w.Reps, &w.UpdatedAt); err != nil {
			return nil, err
		}
		sessions = append(sessions, w)
	}
	return sessions, rows.Err()
}

func (s *Store) DeleteWorkout(ctx context.Context, userID, id string) error {
	_, err := s.pool.Exec(ctx, `
		DELETE FROM workout_sessions WHERE id = $1::uuid AND user_id = $2::uuid`,
		id, userID)
	return err
}
