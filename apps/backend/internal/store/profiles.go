package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// The two whole-document profile stores share one shape: opaque client
// JSON + updated_at. Table names come from this closed set only — never
// from input.
type DocumentKind int

const (
	BodyProfileDocument DocumentKind = iota
	PlateCatalogDocument
)

func (k DocumentKind) table() (string, error) {
	switch k {
	case BodyProfileDocument:
		return "body_profiles", nil
	case PlateCatalogDocument:
		return "plate_catalogs", nil
	}
	return "", fmt.Errorf("unknown document kind %d", k)
}

// Document returns the stored payload; nil when the user has none.
func (s *Store) Document(
	ctx context.Context, kind DocumentKind, userID string,
) (json.RawMessage, time.Time, error) {
	table, err := kind.table()
	if err != nil {
		return nil, time.Time{}, err
	}
	var payload json.RawMessage
	var updatedAt time.Time
	err = s.pool.QueryRow(ctx,
		`SELECT payload, updated_at FROM `+table+` WHERE user_id = $1::uuid`,
		userID,
	).Scan(&payload, &updatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, time.Time{}, nil
	}
	return payload, updatedAt, err
}

func (s *Store) SetDocument(
	ctx context.Context, kind DocumentKind, userID string, payload json.RawMessage,
) error {
	table, err := kind.table()
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		INSERT INTO `+table+` (user_id, payload) VALUES ($1::uuid, $2)
		ON CONFLICT (user_id) DO UPDATE SET payload = EXCLUDED.payload, updated_at = now()`,
		userID, payload)
	return err
}
