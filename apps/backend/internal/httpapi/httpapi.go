// Package httpapi is the HTTP surface: stdlib ServeMux routing (Go 1.22+
// method patterns — ~14 routes make a router dependency pointless),
// middleware, and one handler file per area.
package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/yarik/squatter/backend/internal/config"
	"github.com/yarik/squatter/backend/internal/mailer"
	"github.com/yarik/squatter/backend/internal/store"
)

type Deps struct {
	Store  *store.Store
	Mailer mailer.Mailer
	Cfg    config.Config
	// AnthropicURL is overridable so handler tests can stub the upstream.
	AnthropicURL string
	// Now is injectable for tests; nil = time.Now.
	Now func() time.Time
}

type api struct {
	deps        Deps
	coachClient *http.Client
	ipLimiter   *ipLimiter
}

func New(deps Deps) http.Handler {
	if deps.AnthropicURL == "" {
		deps.AnthropicURL = "https://api.anthropic.com/v1/messages"
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	a := &api{
		deps: deps,
		// The coach call legitimately runs for minutes.
		coachClient: &http.Client{Timeout: 300 * time.Second},
		ipLimiter:   newIPLimiter(10, time.Minute),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.health)
	mux.Handle("POST /v1/auth/request-code", a.limitByIP(http.HandlerFunc(a.requestCode)))
	mux.Handle("POST /v1/auth/verify", a.limitByIP(http.HandlerFunc(a.verify)))
	mux.Handle("POST /v1/auth/logout", a.authed(a.logout))
	mux.Handle("GET /v1/me", a.authed(a.me))
	mux.Handle("POST /v1/coach", a.authed(a.coach))
	mux.Handle("GET /v1/profile/body", a.authed(a.getDocument(store.BodyProfileDocument)))
	mux.Handle("PUT /v1/profile/body", a.authed(a.putDocument(store.BodyProfileDocument)))
	mux.Handle("GET /v1/profile/plates", a.authed(a.getDocument(store.PlateCatalogDocument)))
	mux.Handle("PUT /v1/profile/plates", a.authed(a.putDocument(store.PlateCatalogDocument)))
	mux.Handle("PUT /v1/sessions/{id}", a.authed(a.putSession))
	mux.Handle("GET /v1/sessions", a.authed(a.listSessions))
	mux.Handle("DELETE /v1/sessions/{id}", a.authed(a.deleteSession))

	// Everything gets a 30 s deadline except the coach proxy, which is routed
	// around TimeoutHandler altogether: TimeoutHandler buffers the entire
	// response and its writer does not implement http.Flusher, so wrapping the
	// coach route would hold the SSE relay back until the model finished —
	// recreating the long idle gap that streaming exists to remove. That
	// route carries its own deadline (see coachDeadline in coach_handler.go).
	timed := http.TimeoutHandler(mux, 30*time.Second, `{"error":{"message":"timeout"}}`)
	root := http.NewServeMux()
	root.Handle("POST /v1/coach", mux)
	root.Handle("/", timed)

	return a.logRequests(a.recoverPanics(root))
}

// --- shared helpers ---

type contextKey int

const userKey contextKey = 0

func userFrom(ctx context.Context) *store.User {
	user, _ := ctx.Value(userKey).(*store.User)
	return user
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

type errorBody struct {
	Error errorMessage `json:"error"`
}

type errorMessage struct {
	Message    string `json:"message"`
	RetryAfter int    `json:"retry_after,omitempty"`
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorBody{Error: errorMessage{Message: message}})
}

func (a *api) serverError(w http.ResponseWriter, err error, where string) {
	slog.Error("internal error", "where", where, "err", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

func (a *api) health(w http.ResponseWriter, r *http.Request) {
	if err := a.deps.Store.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "db unreachable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
