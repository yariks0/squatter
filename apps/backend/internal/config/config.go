// Package config parses the API's environment into one struct. Every knob
// the server has lives here; .env.example documents them.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port            string
	DatabaseURL     string
	AnthropicAPIKey string
	CoachModel      string
	CoachDailyLimit int
	ResendAPIKey    string
	EmailFrom       string
	Env             string // "dev" | "prod"
	TokenTTL        time.Duration
	CodeTTL         time.Duration
}

func Load() (Config, error) {
	cfg := Config{
		Port:            getenv("PORT", "8080"),
		DatabaseURL:     os.Getenv("DATABASE_URL"),
		AnthropicAPIKey: os.Getenv("ANTHROPIC_API_KEY"),
		CoachModel:      getenv("COACH_MODEL", "claude-opus-4-8"),
		ResendAPIKey:    os.Getenv("RESEND_API_KEY"),
		EmailFrom:       getenv("EMAIL_FROM", "Squatter <onboarding@resend.dev>"),
		Env:             getenv("ENV", "dev"),
	}
	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("DATABASE_URL is required")
	}
	var err error
	if cfg.CoachDailyLimit, err = getint("COACH_DAILY_LIMIT", 20); err != nil {
		return cfg, err
	}
	tokenDays, err := getint("TOKEN_TTL_DAYS", 90)
	if err != nil {
		return cfg, err
	}
	cfg.TokenTTL = time.Duration(tokenDays) * 24 * time.Hour
	codeMinutes, err := getint("CODE_TTL_MINUTES", 10)
	if err != nil {
		return cfg, err
	}
	cfg.CodeTTL = time.Duration(codeMinutes) * time.Minute
	return cfg, nil
}

func getenv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func getint(key string, fallback int) (int, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return parsed, nil
}
