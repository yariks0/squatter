package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/yarik/squatter/backend/internal/config"
)

// clientIP decides the rate limiter's bucket key, so getting it wrong is
// either a free bypass (trusting a forged header) or a self-inflicted DoS
// (every caller sharing the proxy's bucket). No DB needed — unlike api_test.
func TestClientIP(t *testing.T) {
	cases := []struct {
		name       string
		trustProxy bool
		forwarded  string
		remoteAddr string
		want       string
	}{{
		name:       "direct: peer address",
		remoteAddr: "203.0.113.7:54321",
		want:       "203.0.113.7",
	}, {
		name:       "direct: forged header ignored",
		forwarded:  "1.2.3.4",
		remoteAddr: "203.0.113.7:54321",
		want:       "203.0.113.7",
	}, {
		name:       "proxied: single hop",
		trustProxy: true,
		forwarded:  "203.0.113.7",
		remoteAddr: "172.18.0.3:40000",
		want:       "203.0.113.7",
	}, {
		name:       "proxied: client-forged prefix loses to appended peer",
		trustProxy: true,
		forwarded:  "1.2.3.4, 203.0.113.7",
		remoteAddr: "172.18.0.3:40000",
		want:       "203.0.113.7",
	}, {
		name:       "proxied: no header falls back to peer",
		trustProxy: true,
		remoteAddr: "172.18.0.3:40000",
		want:       "172.18.0.3",
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a := &api{deps: Deps{Cfg: config.Config{TrustProxy: tc.trustProxy}}}
			r := httptest.NewRequest(http.MethodPost, "/v1/auth/request-code", nil)
			r.RemoteAddr = tc.remoteAddr
			if tc.forwarded != "" {
				r.Header.Set("X-Forwarded-For", tc.forwarded)
			}
			if got := a.clientIP(r); got != tc.want {
				t.Errorf("clientIP = %q, want %q", got, tc.want)
			}
		})
	}
}
