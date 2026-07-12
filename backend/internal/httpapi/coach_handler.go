package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/yarik/squatter/backend/internal/coach"
)

const maxCoachBodyBytes = 25 << 20 // keyframes ≈ 100–300 KB each; generous headroom

// coach proxies the app-built Anthropic Messages request: validate, pin the
// model, enforce the daily quota, forward with the server-held key, return
// the upstream response verbatim (CoachClient's parsing stays untouched).
func (a *api) coach(w http.ResponseWriter, r *http.Request) {
	user := userFrom(r.Context())

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxCoachBodyBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "request too large")
		return
	}
	prepared, err := coach.ValidateAndPrepare(body, a.deps.Cfg.CoachModel, coach.DefaultLimits)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	since := a.deps.Now().Truncate(24 * time.Hour)
	calls, err := a.deps.Store.CountCoachCallsSince(r.Context(), user.ID, since)
	if err != nil {
		a.serverError(w, err, "quota lookup")
		return
	}
	if calls >= a.deps.Cfg.CoachDailyLimit {
		writeError(w, http.StatusTooManyRequests,
			"Daily coaching limit reached — try again tomorrow.")
		return
	}

	slog.Info("coach call", "user", user.ID, "bytes", len(prepared))
	status, responseBody, err := coach.Forward(
		r.Context(), a.coachClient, a.deps.AnthropicURL, a.deps.Cfg.AnthropicAPIKey, prepared)
	if err != nil {
		a.serverError(w, err, "anthropic forward")
		return
	}

	inputTokens, outputTokens := coach.Usage(responseBody)
	if err := a.deps.Store.InsertCoachUsage(
		r.Context(), user.ID, a.deps.Cfg.CoachModel, inputTokens, outputTokens, status,
	); err != nil {
		slog.Warn("usage insert failed", "err", err)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(responseBody)
}
