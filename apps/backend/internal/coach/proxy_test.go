package coach

import (
	"encoding/json"
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

func TestUsageParsing(t *testing.T) {
	in, out := Usage([]byte(`{"usage":{"input_tokens":120,"output_tokens":45}}`))
	if in == nil || *in != 120 || out == nil || *out != 45 {
		t.Fatalf("usage parse: in=%v out=%v", in, out)
	}
	if in, out := Usage([]byte(`{"type":"error"}`)); in != nil || out != nil {
		t.Fatal("expected nil usage on error response")
	}
}
