// Command api is the Squatter backend: passwordless auth, the coach proxy,
// and profile/progress sync. It self-migrates on boot, so compose needs no
// migrate sidecar.
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/yarik/squatter/backend/internal/config"
	"github.com/yarik/squatter/backend/internal/httpapi"
	"github.com/yarik/squatter/backend/internal/mailer"
	"github.com/yarik/squatter/backend/internal/store"
	"github.com/yarik/squatter/backend/migrations"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	// The image is distroless — no shell, no curl — so the container
	// healthcheck re-runs this binary as `/api -healthcheck`. It probes
	// /healthz and exits 0/1. Handled before config.Load: a probe has no
	// DATABASE_URL and must not need one.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		if err := healthcheck(); err != nil {
			slog.Error("healthcheck", "err", err)
			os.Exit(1)
		}
		return
	}

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	if err := run(cfg); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(cfg config.Config) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := migrate(cfg.DatabaseURL); err != nil {
		return err
	}

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	deps := httpapi.Deps{
		Store:  store.New(pool),
		Mailer: chooseMailer(cfg),
		Cfg:    cfg,
	}
	handler := httpapi.New(deps)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("listening", "port", cfg.Port, "env", cfg.Env)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("serve", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return server.Shutdown(shutdownCtx)
}

func healthcheck() error {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func chooseMailer(cfg config.Config) mailer.Mailer {
	if cfg.ResendAPIKey == "" {
		slog.Warn("RESEND_API_KEY unset — login codes go to the server log")
		return mailer.Log{}
	}
	return mailer.NewResend(cfg.ResendAPIKey, cfg.EmailFrom)
}

// migrate runs the embedded goose migrations against a short-lived
// database/sql handle (goose's driver), separate from the pgx pool the
// server runs on.
func migrate(databaseURL string) error {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	goose.SetBaseFS(migrations.FS)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	return goose.Up(db, ".")
}

// Keep the pgx stdlib driver import referenced (registers "pgx" for goose).
var _ = stdlib.GetDefaultDriver
