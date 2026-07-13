// Package mailer sends the login codes. The interface exists so dev runs
// (LogMailer, code printed to stdout) and tests (fakes) need no Resend
// account.
package mailer

import (
	"context"
	"log/slog"
)

type Mailer interface {
	SendLoginCode(ctx context.Context, to, code string) error
}

// Log is the dev mailer: the code lands in the server log instead of an
// inbox (`docker compose logs api`).
type Log struct{}

func (Log) SendLoginCode(_ context.Context, to, code string) error {
	slog.Info("login code (dev mailer)", "email", to, "code", code)
	return nil
}
