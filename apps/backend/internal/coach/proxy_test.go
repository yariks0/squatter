package coach

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func minimalBody(t *testing.T, extra map[string]any) []byte {
	t.Helper()
	body := map[string]any{
		"model":      "claude-should-be-overwritten",
		"max_tokens": 24000,
		"messages": []any{
			map[string]any{"role": "user", "content": "hi"},
		},
	}
	for key, value := range extra {
		body[key] = value
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestValidateOverwritesModel(t *testing.T) {
	prepared, err := ValidateAndPrepare(minimalBody(t, nil), "claude-opus-4-8", DefaultLimits)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(prepared, &out); err != nil {
		t.Fatal(err)
	}
	if out["model"] != "claude-opus-4-8" {
		t.Fatalf("model not pinned: %v", out["model"])
	}
}

func TestValidateRejectsUnknownField(t *testing.T) {
	body := minimalBody(t, map[string]any{"tools": []any{}})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection of unexpected field")
	}
}

func TestValidateRejectsHighMaxTokens(t *testing.T) {
	body := minimalBody(t, map[string]any{"max_tokens": 100000})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection of oversized max_tokens")
	}
}

func TestValidateMaxTokensCapBoundary(t *testing.T) {
	atCap := minimalBody(t, map[string]any{"max_tokens": DefaultLimits.MaxTokens})
	if _, err := ValidateAndPrepare(atCap, "m", DefaultLimits); err != nil {
		t.Fatalf("max_tokens at the cap should pass: %v", err)
	}
	overCap := minimalBody(t, map[string]any{"max_tokens": DefaultLimits.MaxTokens + 1})
	if _, err := ValidateAndPrepare(overCap, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection one over the cap")
	}
}

func TestValidateRejectsMultipleMessages(t *testing.T) {
	body := minimalBody(t, map[string]any{"messages": []any{
		map[string]any{"role": "user", "content": "a"},
		map[string]any{"role": "user", "content": "b"},
	}})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection of multiple messages")
	}
}

func TestValidateRejectsTooManyImages(t *testing.T) {
	blocks := make([]any, 0, DefaultLimits.MaxImages+1)
	for range DefaultLimits.MaxImages + 1 {
		blocks = append(blocks, map[string]any{
			"type":   "image",
			"source": map[string]any{"type": "base64", "data": "AAAA"},
		})
	}
	body := minimalBody(t, map[string]any{"messages": []any{
		map[string]any{"role": "user", "content": blocks},
	}})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection past the image cap")
	}
}

func TestValidateRejectsOversizedImage(t *testing.T) {
	// base64 length ~4/3 of decoded bytes; exceed the 2 MB decoded cap.
	huge := strings.Repeat("A", (DefaultLimits.MaxImageBytes+1)*4/3+8)
	body := minimalBody(t, map[string]any{"messages": []any{
		map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "image",
				"source": map[string]any{"type": "base64", "data": huge}},
		}},
	}})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err == nil {
		t.Fatal("expected rejection of oversized image block")
	}
}

func TestValidateAcceptsRealShape(t *testing.T) {
	body := minimalBody(t, map[string]any{
		"thinking":      map[string]any{"type": "adaptive"},
		"system":        "you are a coach",
		"output_config": map[string]any{"format": map[string]any{"type": "json_schema"}},
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "rep 1"},
				map[string]any{"type": "image",
					"source": map[string]any{"type": "base64", "data": "AAAA"}},
			}},
		},
	})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err != nil {
		t.Fatalf("valid body rejected: %v", err)
	}
}

func TestValidateAcceptsStream(t *testing.T) {
	body := minimalBody(t, map[string]any{"stream": true})
	if _, err := ValidateAndPrepare(body, "m", DefaultLimits); err != nil {
		t.Fatalf("stream should be an allowed field: %v", err)
	}
}

// An SSE reply must reach the client incrementally: the whole point is that no
// idle gap forms while the model works, so a flush has to land before the
// stream ends.
func TestForwardStreamsAndFlushesSSE(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			for _, line := range []string{
				`data: {"type":"message_start","message":{"usage":{"input_tokens":120}}}`,
				`data: {"type":"content_block_delta","delta":{"text":"{"}}`,
				`data: {"type":"message_delta","usage":{"output_tokens":45}}`,
			} {
				_, _ = w.Write([]byte(line + "\n\n"))
				w.(http.Flusher).Flush()
			}
		}))
	defer upstream.Close()

	recorder := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}
	result, err := Forward(
		context.Background(), upstream.Client(), upstream.URL, "k", []byte("{}"), recorder)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != http.StatusOK {
		t.Fatalf("status: %d", result.Status)
	}
	if result.InputTokens == nil || *result.InputTokens != 120 ||
		result.OutputTokens == nil || *result.OutputTokens != 45 {
		t.Fatalf("usage scraped from stream: in=%v out=%v",
			result.InputTokens, result.OutputTokens)
	}
	if recorder.flushes == 0 {
		t.Fatal("stream was buffered, not flushed — the idle gap would return")
	}
	if got := recorder.Header().Get("Content-Type"); got != contentTypeSSE {
		t.Fatalf("content type not relayed: %q", got)
	}
	if !strings.Contains(recorder.Body.String(), `"content_block_delta"`) {
		t.Fatal("event body not relayed verbatim")
	}
}

// A non-SSE upstream reply (an error, or an older app that omits `stream`)
// still relays whole, with usage read off the JSON body.
func TestForwardRelaysNonStreamingBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"usage":{"input_tokens":7,"output_tokens":3}}`))
		}))
	defer upstream.Close()

	recorder := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}
	result, err := Forward(
		context.Background(), upstream.Client(), upstream.URL, "k", []byte("{}"), recorder)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != http.StatusOK || result.InputTokens == nil || *result.InputTokens != 7 ||
		result.OutputTokens == nil || *result.OutputTokens != 3 {
		t.Fatalf("non-stream relay: %+v", result)
	}
}

// Forward reports status 0 when it never wrote anything, which is what lets
// the handler still send a real error response.
func TestForwardReportsUnwrittenFailure(t *testing.T) {
	recorder := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}
	result, err := Forward(context.Background(), http.DefaultClient,
		"http://127.0.0.1:1", "k", []byte("{}"), recorder)
	if err == nil {
		t.Fatal("expected a dial failure")
	}
	if result.Status != 0 {
		t.Fatalf("status should be 0 when nothing was written, got %d", result.Status)
	}
}

// TextBytes must size the report alone. Thinking shares the stream and dwarfs
// it, so counting thinking deltas would hide exactly the empty-report case
// this measurement exists to expose.
func TestForwardCountsTextBytesExcludingThinking(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			for _, line := range []string{
				`data: {"type":"content_block_delta","index":0,` +
					`"delta":{"type":"thinking_delta","thinking":"` +
					strings.Repeat("z", 5000) + `"}}`,
				`data: {"type":"content_block_delta","index":1,` +
					`"delta":{"type":"text_delta","text":"{\"summary\":\"\"}"}}`,
			} {
				_, _ = w.Write([]byte(line + "\n\n"))
				w.(http.Flusher).Flush()
			}
		}))
	defer upstream.Close()

	recorder := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}
	result, err := Forward(
		context.Background(), upstream.Client(), upstream.URL, "k", []byte("{}"), recorder)
	if err != nil {
		t.Fatal(err)
	}
	if result.TextBytes != len(`{"summary":""}`) {
		t.Fatalf("text bytes should count text_delta only, got %d", result.TextBytes)
	}
	if result.TextBytes >= EmptyReportBytes {
		t.Fatal("an empty report should fall under the empty-report threshold")
	}
}

type flushRecorder struct {
	*httptest.ResponseRecorder
	flushes int
}

func (f *flushRecorder) Flush() { f.flushes++; f.ResponseRecorder.Flush() }

func TestUsageParsing(t *testing.T) {
	in, out := Usage([]byte(`{"usage":{"input_tokens":120,"output_tokens":45}}`))
	if in == nil || *in != 120 || out == nil || *out != 45 {
		t.Fatalf("usage parse: in=%v out=%v", in, out)
	}
	if in, out := Usage([]byte(`{"type":"error"}`)); in != nil || out != nil {
		t.Fatal("expected nil usage on error response")
	}
}
