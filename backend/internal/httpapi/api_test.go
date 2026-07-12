package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yarik/squatter/backend/internal/config"
	"github.com/yarik/squatter/backend/internal/httpapi"
	"github.com/yarik/squatter/backend/internal/store"
)

// fakeMailer captures the last code so tests can "read the email".
type fakeMailer struct{ lastCode string }

func (m *fakeMailer) SendLoginCode(_ context.Context, _, code string) error {
	m.lastCode = code
	return nil
}

// harness wires the real handler against the compose Postgres (set
// TEST_DATABASE_URL) with a stubbed Anthropic upstream and a controllable
// clock. Skips when no test DB is configured.
type harness struct {
	server   *httptest.Server
	mailer   *fakeMailer
	pool     *pgxpool.Pool
	now      time.Time
	upstream *httptest.Server
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	// Isolate each test.
	_, err = pool.Exec(context.Background(),
		`TRUNCATE users, auth_codes, sessions, workout_sessions,
		 body_profiles, plate_catalogs, coach_usage CASCADE`)
	if err != nil {
		t.Fatal(err)
	}

	h := &harness{mailer: &fakeMailer{}, pool: pool, now: time.Now().UTC()}

	// Stub Anthropic: echoes a Messages-shaped response with usage.
	h.upstream = httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("x-api-key") != "server-key" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte(
				`{"content":[{"type":"text","text":"{}"}],` +
					`"usage":{"input_tokens":10,"output_tokens":5}}`))
		}))
	t.Cleanup(h.upstream.Close)

	handler := httpapi.New(httpapi.Deps{
		Store:        store.New(pool),
		Mailer:       h.mailer,
		AnthropicURL: h.upstream.URL,
		Now:          func() time.Time { return h.now },
		Cfg: config.Config{
			AnthropicAPIKey: "server-key",
			CoachModel:      "claude-pinned",
			CoachDailyLimit: 2,
			TokenTTL:        90 * 24 * time.Hour,
			CodeTTL:         10 * time.Minute,
		},
	})
	h.server = httptest.NewServer(handler)
	t.Cleanup(h.server.Close)
	return h
}

func (h *harness) do(t *testing.T, method, path, token, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, h.server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// login runs the full request-code → verify flow and returns the token.
func (h *harness) login(t *testing.T, email string) string {
	t.Helper()
	if resp := h.do(t, "POST", "/v1/auth/request-code", "",
		`{"email":"`+email+`"}`); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("request-code: %d", resp.StatusCode)
	}
	resp := h.do(t, "POST", "/v1/auth/verify", "",
		`{"email":"`+email+`","code":"`+h.mailer.lastCode+`"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("verify: %d", resp.StatusCode)
	}
	var out struct {
		Token string `json:"token"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return out.Token
}

func TestLoginFlowAndMe(t *testing.T) {
	h := newHarness(t)
	token := h.login(t, "a@example.com")

	resp := h.do(t, "GET", "/v1/me", token, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("me: %d", resp.StatusCode)
	}
	// Logout revokes the token.
	if resp := h.do(t, "POST", "/v1/auth/logout", token, ""); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("logout: %d", resp.StatusCode)
	}
	if resp := h.do(t, "GET", "/v1/me", token, ""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("me after logout: %d", resp.StatusCode)
	}
}

func TestWrongCodeAttemptCapInvalidates(t *testing.T) {
	h := newHarness(t)
	if resp := h.do(t, "POST", "/v1/auth/request-code", "",
		`{"email":"b@example.com"}`); resp.StatusCode != http.StatusNoContent {
		t.Fatal("request-code failed")
	}
	good := h.mailer.lastCode
	for range 5 {
		h.do(t, "POST", "/v1/auth/verify", "", `{"email":"b@example.com","code":"000000"}`)
	}
	// Even the correct code is dead once the attempt cap is spent.
	resp := h.do(t, "POST", "/v1/auth/verify", "",
		`{"email":"b@example.com","code":"`+good+`"}`)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 after attempt cap, got %d", resp.StatusCode)
	}
}

func TestCoachForwardsAndAccountsUsage(t *testing.T) {
	h := newHarness(t)
	token := h.login(t, "c@example.com")
	body := `{"model":"ignored","max_tokens":16000,` +
		`"messages":[{"role":"user","content":"hi"}]}`

	resp := h.do(t, "POST", "/v1/coach", token, body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("coach: %d", resp.StatusCode)
	}
	// Usage row recorded with the pinned model + upstream token counts.
	var model string
	var inTok int
	err := h.pool.QueryRow(context.Background(),
		`SELECT model, input_tokens FROM coach_usage LIMIT 1`).Scan(&model, &inTok)
	if err != nil {
		t.Fatal(err)
	}
	if model != "claude-pinned" || inTok != 10 {
		t.Fatalf("usage row: model=%s input=%d", model, inTok)
	}

	// Second call ok (limit 2), third hits the daily quota.
	h.do(t, "POST", "/v1/coach", token, body)
	if resp := h.do(t, "POST", "/v1/coach", token, body); resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on quota, got %d", resp.StatusCode)
	}
}

func TestSessionsScopedToUser(t *testing.T) {
	h := newHarness(t)
	alice := h.login(t, "alice@example.com")
	bob := h.login(t, "bob@example.com")
	id := "11111111-2222-3333-4444-555555555555"

	h.do(t, "PUT", "/v1/sessions/"+id, alice,
		`{"date":"2026-07-10T12:00:00Z","activity":"squat","score":88,`+
			`"rep_count":5,"used_lidar":true,"weight_kg":100,"reps":[]}`)

	// Bob sees none of Alice's sessions.
	resp := h.do(t, "GET", "/v1/sessions", bob, "")
	var out struct {
		Sessions []json.RawMessage `json:"sessions"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if len(out.Sessions) != 0 {
		t.Fatalf("bob saw %d of alice's sessions", len(out.Sessions))
	}
}
