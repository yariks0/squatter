// Package coach guards the pass-through to the Anthropic Messages API. The
// iOS app keeps building the request body (CoachPrompt embeds live analysis
// thresholds and mirrors CoachReport — a Go copy would rot into a three-way
// sync); the server validates shape and size, pins the model, injects the
// API key, and returns Anthropic's response verbatim so the client parser
// never changes.
package coach

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type Limits struct {
	MaxTokens     int // cap on the request's max_tokens
	MaxImages     int
	MaxImageBytes int // decoded size per image block
}

var DefaultLimits = Limits{MaxTokens: 24000, MaxImages: 30, MaxImageBytes: 2 << 20}

// allowedKeys is the closed set of top-level Messages-API fields the app
// legitimately sends; anything else is rejected rather than forwarded.
var allowedKeys = map[string]bool{
	"model": true, "max_tokens": true, "thinking": true,
	"system": true, "messages": true, "output_config": true,
	"stream": true,
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

// Forward posts the prepared body with the server-held key and relays
// Anthropic's response to w verbatim, returning the upstream status and token
// usage. A returned status of 0 means nothing was written to w yet, so the
// caller may still send an error response.
//
// When the app asks for `"stream": true` the upstream answers with SSE, and
// every line is flushed onward as it arrives. That matters for more than
// latency: a buffered coach call sends no bytes for ~90 s while the model
// works, and an idle connection that long is torn down by the QUIC/HTTP-3
// idle timeout at the TLS edge (observed: Caddy 504 "timeout: no recent
// network activity" after 58 s). A continuously flowing stream never idles.
// Non-SSE replies — upstream errors, or an older app that omits `stream` —
// are small, so they are relayed whole.
func Forward(
	ctx context.Context, client *http.Client, url, apiKey string,
	body []byte, w http.ResponseWriter,
) (int, *int, *int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("x-api-key", apiKey)
	request.Header.Set("anthropic-version", "2023-06-01")
	response, err := client.Do(request)
	if err != nil {
		return 0, nil, nil, err
	}
	defer response.Body.Close()

	contentType := response.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/json"
	}
	if !strings.Contains(contentType, "text/event-stream") {
		responseBody, err := io.ReadAll(response.Body)
		if err != nil {
			return 0, nil, nil, err
		}
		w.Header().Set("Content-Type", contentType)
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(responseBody)
		inputTokens, outputTokens := Usage(responseBody)
		return response.StatusCode, inputTokens, outputTokens, nil
	}
	return relayStream(response, w)
}

// relayStream copies an SSE body line by line, flushing each one so no idle
// gap forms, and scrapes token usage from the events on their way past.
func relayStream(response *http.Response, w http.ResponseWriter) (int, *int, *int, error) {
	w.Header().Set("Content-Type", contentTypeSSE)
	// Proxies that buffer would reintroduce exactly the idle gap streaming
	// exists to avoid.
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(response.StatusCode)
	flusher, _ := w.(http.Flusher)
	if flusher != nil {
		flusher.Flush() // send headers now, before the model's first token
	}

	var inputTokens, outputTokens *int
	reader := bufio.NewReader(response.Body)
	for {
		// ReadBytes rather than bufio.Scanner: a single SSE line has no
		// useful upper bound and Scanner would fail the whole stream on one
		// long one.
		line, readErr := reader.ReadBytes('\n')
		if len(line) > 0 {
			if _, writeErr := w.Write(line); writeErr != nil {
				return response.StatusCode, inputTokens, outputTokens, writeErr
			}
			if flusher != nil {
				flusher.Flush()
			}
			scrapeUsage(line, &inputTokens, &outputTokens)
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return response.StatusCode, inputTokens, outputTokens, nil
			}
			return response.StatusCode, inputTokens, outputTokens, readErr
		}
	}
}

const contentTypeSSE = "text/event-stream"

// scrapeUsage pulls token counts out of a passing SSE line. `message_start`
// carries the input count on a nested message; `message_delta` carries the
// running output count at the top level. Later values overwrite earlier ones,
// so the final delta wins.
func scrapeUsage(line []byte, inputTokens, outputTokens **int) {
	data, found := bytes.CutPrefix(bytes.TrimSpace(line), []byte("data:"))
	if !found {
		return
	}
	var event struct {
		Message struct {
			Usage tokenUsage `json:"usage"`
		} `json:"message"`
		Usage tokenUsage `json:"usage"`
	}
	if json.Unmarshal(bytes.TrimSpace(data), &event) != nil {
		return
	}
	for _, usage := range []tokenUsage{event.Message.Usage, event.Usage} {
		if usage.InputTokens != nil {
			*inputTokens = usage.InputTokens
		}
		if usage.OutputTokens != nil {
			*outputTokens = usage.OutputTokens
		}
	}
}

type tokenUsage struct {
	InputTokens  *int `json:"input_tokens"`
	OutputTokens *int `json:"output_tokens"`
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
