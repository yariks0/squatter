// Package migrations embeds the goose SQL migrations so the API binary
// self-migrates at startup — no migrate sidecar in compose.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
