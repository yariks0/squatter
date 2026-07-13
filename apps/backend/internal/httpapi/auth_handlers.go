package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/yarik/squatter/backend/internal/auth"
)

const (
	resendCooldown  = 60 * time.Second
	codesPerHourCap = 5
)

// requestCode behaves identically for known and unknown emails (users are
// created lazily on first successful verify), so it can't leak account
// existence. 204 on success; 429 only for rate limits.
func (a *api) requestCode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	email, ok := normalizeEmail(body.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid email")
		return
	}
	now := a.deps.Now()

	newest, err := a.deps.Store.NewestCodeCreatedAt(r.Context(), email)
	if err != nil {
		a.serverError(w, err, "cooldown lookup")
		return
	}
	if wait := resendCooldown - now.Sub(newest); !newest.IsZero() && wait > 0 {
		writeJSON(w, http.StatusTooManyRequests, errorBody{Error: errorMessage{
			Message:    "a code was just sent — wait before requesting another",
			RetryAfter: int(wait.Seconds()) + 1,
		}})
		return
	}
	recent, err := a.deps.Store.CountCodesSince(r.Context(), email, now.Add(-time.Hour))
	if err != nil {
		a.serverError(w, err, "hourly cap lookup")
		return
	}
	if recent >= codesPerHourCap {
		writeError(w, http.StatusTooManyRequests, "too many codes requested — try again later")
		return
	}

	code, err := auth.GenerateCode()
	if err != nil {
		a.serverError(w, err, "code generation")
		return
	}
	salt, err := auth.NewSalt()
	if err != nil {
		a.serverError(w, err, "salt generation")
		return
	}
	if err := a.deps.Store.InsertAuthCode(
		r.Context(), email, auth.HashCode(salt, code), salt, now.Add(a.deps.Cfg.CodeTTL),
	); err != nil {
		a.serverError(w, err, "code insert")
		return
	}
	if err := a.deps.Mailer.SendLoginCode(r.Context(), email, code); err != nil {
		a.serverError(w, err, "send email")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// verify exchanges email+code for a bearer token. Every failure is the same
// generic 401.
func (a *api) verify(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	email, ok := normalizeEmail(body.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid email")
		return
	}
	now := a.deps.Now()

	code, err := a.deps.Store.LatestAuthCode(r.Context(), email, now)
	if err != nil {
		a.serverError(w, err, "code lookup")
		return
	}
	if code == nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}
	// Pre-increment so parallel guesses each consume an attempt.
	attempts, err := a.deps.Store.IncrementAttempts(r.Context(), code.ID)
	if err != nil {
		a.serverError(w, err, "attempt increment")
		return
	}
	if attempts > auth.MaxCodeAttempts ||
		!auth.CodeMatches(code.CodeHash, code.Salt, strings.TrimSpace(body.Code)) {
		writeError(w, http.StatusUnauthorized, "invalid or expired code")
		return
	}

	if err := a.deps.Store.ConsumeAuthCode(r.Context(), code.ID, email, now); err != nil {
		a.serverError(w, err, "code consume")
		return
	}
	user, err := a.deps.Store.UpsertUser(r.Context(), email)
	if err != nil {
		a.serverError(w, err, "user upsert")
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		a.serverError(w, err, "token mint")
		return
	}
	if err := a.deps.Store.InsertSession(
		r.Context(), user.ID, tokenHash, now.Add(a.deps.Cfg.TokenTTL),
	); err != nil {
		a.serverError(w, err, "session insert")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token,
		"user":  map[string]string{"id": user.ID, "email": user.Email},
	})
}

func (a *api) logout(w http.ResponseWriter, r *http.Request) {
	token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if err := a.deps.Store.DeleteSessionByTokenHash(r.Context(), auth.HashToken(token)); err != nil {
		a.serverError(w, err, "session delete")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) me(w http.ResponseWriter, r *http.Request) {
	user := userFrom(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"id": user.ID, "email": user.Email, "created_at": user.CreatedAt,
	})
}

// normalizeEmail lowercases/trims and applies the minimal sanity check —
// real validation is receiving the code.
func normalizeEmail(email string) (string, bool) {
	email = strings.ToLower(strings.TrimSpace(email))
	at := strings.Index(email, "@")
	valid := len(email) <= 254 && at > 0 && at < len(email)-1 && !strings.ContainsAny(email, " \t\n")
	return email, valid
}
