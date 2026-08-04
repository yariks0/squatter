package httpapi

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/yarik/squatter/backend/internal/coach"
)

const maxCoachBodyBytes = 25 << 20 // keyframes ≈ 100–300 KB each; generous headroom

// coachDeadline bounds one coach call end to end. It sits above the 300 s
// upstream client timeout so Anthropic is always the first to give up.
const coachDeadline = 310 * time.Second

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
	// This route is deliberately outside the mux-wide TimeoutHandler (see
	// httpapi.New): TimeoutHandler buffers the whole response and its writer
	// is not an http.Flusher, which would silently undo the streaming relay.
	// The deadline lives here instead, where it bounds the call without
	// holding the bytes back.
	ctx, cancel := context.WithTimeout(r.Context(), coachDeadline)
	defer cancel()

	result, err := coach.Forward(
		ctx, a.coachClient, a.deps.AnthropicURL, a.deps.Cfg.AnthropicAPIKey, prepared, w)
	if err != nil {
		if result.Status == 0 {
			// Nothing written yet, so a normal error response is still valid.
			a.serverError(w, err, "anthropic forward")
			return
		}
		// Mid-stream failure: the status line is long gone, so the client
		// sees a truncated stream. Record it rather than pretending success.
		slog.Warn("coach stream interrupted", "user", user.ID, "err", err)
	}

	// text_bytes is the diagnostic that token counts can't give: thinking
	// dominates output_tokens, so a blank report and a real one look alike
	// there but differ by an order of magnitude here.
	slog.Info("coach reply", "user", user.ID, "status", result.Status,
		"text_bytes", result.TextBytes, "output_tokens", result.OutputTokens)
	if result.Status == http.StatusOK && result.TextBytes < coach.EmptyReportBytes {
		slog.Warn("coach returned an empty report",
			"user", user.ID, "text_bytes", result.TextBytes,
			"output_tokens", result.OutputTokens)
	}

	// The call reached Anthropic and consumed quota even if the client hung up
	// on the way back, so account for it on a context that outlives the
	// request rather than losing the row to the cancellation.
	if err := a.deps.Store.InsertCoachUsage(
		context.WithoutCancel(r.Context()),
		user.ID, a.deps.Cfg.CoachModel, result.InputTokens, result.OutputTokens, result.Status,
	); err != nil {
		slog.Warn("usage insert failed", "err", err)
	}
}
