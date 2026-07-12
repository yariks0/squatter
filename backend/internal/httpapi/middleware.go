package httpapi

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/yarik/squatter/backend/internal/auth"
)

// authed resolves the bearer token to a user and slides the session expiry
// (at most one write per 24 h — the sliding window is 90 days, a daily
// touch is plenty).
func (a *api) authed(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeError(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		now := a.deps.Now()
		session, user, err := a.deps.Store.SessionByTokenHash(
			r.Context(), auth.HashToken(token), now)
		if err != nil {
			a.serverError(w, err, "session lookup")
			return
		}
		if session == nil {
			writeError(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		if now.Sub(session.LastUsedAt) > 24*time.Hour {
			if err := a.deps.Store.TouchSession(
				r.Context(), session.ID, now, now.Add(a.deps.Cfg.TokenTTL)); err != nil {
				slog.Warn("session touch failed", "err", err)
			}
		}
		next(w, r.WithContext(context.WithValue(r.Context(), userKey, user)))
	})
}

func (a *api) recoverPanics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				slog.Error("panic", "err", recovered, "stack", string(debug.Stack()))
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (a *api) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		attrs := []any{
			"method", r.Method, "path", r.URL.Path,
			"status", recorder.status, "ms", time.Since(start).Milliseconds(),
		}
		if user := userFrom(r.Context()); user != nil {
			attrs = append(attrs, "user", user.ID)
		}
		slog.Info("request", attrs...)
	})
}

// ipLimiter rate-limits the unauthenticated auth endpoints per client IP.
// In-memory is correct here forever: the deployment is a single instance
// (compose), and losing counters on restart is harmless.
type ipLimiter struct {
	mu       sync.Mutex
	limiters map[string]*rate.Limiter
	perMin   int
	window   time.Duration
}

func newIPLimiter(perMinute int, window time.Duration) *ipLimiter {
	return &ipLimiter{
		limiters: map[string]*rate.Limiter{},
		perMin:   perMinute,
		window:   window,
	}
}

func (l *ipLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	// Crude memory cap; a full map is an abuse signal, not a scale one.
	if len(l.limiters) > 10_000 {
		l.limiters = map[string]*rate.Limiter{}
	}
	limiter, ok := l.limiters[ip]
	if !ok {
		limiter = rate.NewLimiter(rate.Every(l.window/time.Duration(l.perMin)), l.perMin)
		l.limiters[ip] = limiter
	}
	return limiter.Allow()
}

func (a *api) limitByIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		if !a.ipLimiter.allow(ip) {
			writeError(w, http.StatusTooManyRequests, "too many requests")
			return
		}
		next.ServeHTTP(w, r)
	})
}
