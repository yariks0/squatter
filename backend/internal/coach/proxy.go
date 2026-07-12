// Package coach guards the pass-through to the Anthropic Messages API. The
// iOS app keeps building the request body (CoachPrompt embeds live analysis
// thresholds and mirrors CoachReport — a Go copy would rot into a three-way
// sync); the server validates shape and size, pins the model, injects the
// API key, and returns Anthropic's response verbatim so the client parser
// never changes.
package coach

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

type Limits struct {
	MaxTokens     int // cap on the request's max_tokens
	MaxImages     int
	MaxImageBytes int // decoded size per image block
}

var DefaultLimits = Limits{MaxTokens: 16000, MaxImages: 30, MaxImageBytes: 2 << 20}

// allowedKeys is the closed set of top-level Messages-API fields the app
// legitimately sends; anything else is rejected rather than forwarded.
var allowedKeys = map[string]bool{
	"model": true, "max_tokens": true, "thinking": true,
	"system": true, "messages": true, "output_config": true,
}

// ValidateAndPrepare checks the client body and returns it re-marshaled
// with the model pinned to `model` — a stolen token can't run arbitrary
// models or payloads on the server's key.
func ValidateAndPrepare(body []byte, model string, limits Limits) ([]byte, error) {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("body is not JSON: %w", err)
	}
	for key := range payload {
		if !allowedKeys[key] {
			return nil, fmt.Errorf("unexpected field %q", key)
		}
	}
	if maxTokens, ok := payload["max_tokens"].(float64); ok {
		if int(maxTokens) > limits.MaxTokens {
			return nil, fmt.Errorf("max_tokens %d over the %d cap", int(maxTokens), limits.MaxTokens)
		}
	}
	messages, ok := payload["messages"].([]any)
	if !ok || len(messages) != 1 {
		return nil, fmt.Errorf("expected exactly one message")
	}
	if err := validateImages(messages, limits); err != nil {
		return nil, err
	}
	payload["model"] = model
	return json.Marshal(payload)
}

func validateImages(messages []any, limits Limits) error {
	images := 0
	for _, rawMessage := range messages {
		message, ok := rawMessage.(map[string]any)
		if !ok {
			return fmt.Errorf("malformed message")
		}
		blocks, ok := message["content"].([]any)
		if !ok {
			continue // plain-string content carries no images
		}
		for _, rawBlock := range blocks {
			block, ok := rawBlock.(map[string]any)
			if !ok || block["type"] != "image" {
				continue
			}
			images++
			if images > limits.MaxImages {
				return fmt.Errorf("more than %d image blocks", limits.MaxImages)
			}
			source, _ := block["source"].(map[string]any)
			data, _ := source["data"].(string)
			if len(data)/4*3 > limits.MaxImageBytes {
				return fmt.Errorf("image block over %d bytes", limits.MaxImageBytes)
			}
		}
	}
	return nil
}

// Forward posts the prepared body with the server-held key and returns
// Anthropic's status and body verbatim.
func Forward(
	ctx context.Context, client *http.Client, url, apiKey string, body []byte,
) (int, []byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("x-api-key", apiKey)
	request.Header.Set("anthropic-version", "2023-06-01")
	response, err := client.Do(request)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return 0, nil, err
	}
	return response.StatusCode, responseBody, nil
}

// Usage pulls the token counts out of a Messages response for accounting;
// nils when absent (error responses).
func Usage(responseBody []byte) (inputTokens, outputTokens *int) {
	var payload struct {
		Usage struct {
			InputTokens  *int `json:"input_tokens"`
			OutputTokens *int `json:"output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(responseBody, &payload); err != nil {
		return nil, nil
	}
	return payload.Usage.InputTokens, payload.Usage.OutputTokens
}
