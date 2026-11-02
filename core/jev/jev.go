// Package jev asks TypeSafe's System One API (Jev) typed questions about
// a piece of text: a choice among options, or whether something holds,
// each with a probability. The dial uses it to tell a command from
// dictation and to pick the app a command names.
package jev

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const (
	DefaultBaseURL = "https://api.typesafe.ai/v1"
	DefaultModel   = "jev-latest"
)

// Client talks to one System One endpoint.
type Client struct {
	BaseURL string
	APIKey  string
	Model   string
	HTTP    *http.Client
}

// Configured once there is a key.
func (c Client) Configured() bool { return strings.TrimSpace(c.APIKey) != "" }

// URL is the endpoint: the base as the docs give it, with /v1 or
// /v1/systemone already on it or not.
func (c Client) URL() string {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		base = DefaultBaseURL
	}
	if strings.HasSuffix(base, "/systemone") {
		return base
	}
	if !strings.HasSuffix(base, "/v1") {
		base += "/v1"
	}
	return base + "/systemone"
}

// Question is one judgment: a "choice" among Criteria, or a "noul" (yes
// or no).
type Question struct {
	Type         string            `json:"type"`
	Instructions string            `json:"instructions"`
	Criteria     map[string]string `json:"criteria,omitempty"`
}

// Choice picks one of the criteria.
func Choice(instructions string, criteria map[string]string) Question {
	return Question{Type: "choice", Instructions: instructions, Criteria: criteria}
}

// Noul is whether a condition holds.
func Noul(instructions string) Question {
	return Question{Type: "noul", Instructions: instructions}
}

// Answer is one question's: the Choice and its Probabilities, or Noul's
// probability of yes.
type Answer struct {
	Type          string             `json:"type"`
	Choice        string             `json:"choice,omitempty"`
	Confidence    float64            `json:"confidence,omitempty"`
	Probabilities map[string]float64 `json:"probabilities,omitempty"`
	Noul          float64            `json:"noul,omitempty"`
}

// P is the probability of option.
func (a Answer) P(option string) float64 { return a.Probabilities[option] }

// Response is the API's.
type Response struct {
	Model   string            `json:"model"`
	Answers map[string]Answer `json:"answers"`
	Usage   struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

// Ask evaluates every question against state in one request.
func (c Client) Ask(ctx context.Context, state any, questions map[string]Question) (*Response, error) {
	if !c.Configured() {
		return nil, errors.New("jev is not set up: no API key")
	}
	model := strings.TrimSpace(c.Model)
	if model == "" {
		model = DefaultModel
	}
	body, err := json.Marshal(map[string]any{"model": model, "state": state, "questions": questions})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(c.APIKey))
	client := c.HTTP
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jev: HTTP %d %s", resp.StatusCode, excerpt(data))
	}
	var out Response
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("jev: unreadable reply: %w", err)
	}
	if out.Answers == nil {
		return nil, errors.New("jev: a reply without answers")
	}
	return &out, nil
}

// Test asks the smallest question: whether the key and endpoint work.
func (c Client) Test(ctx context.Context) (time.Duration, error) {
	started := time.Now()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	resp, err := c.Ask(ctx, map[string]any{"text": "ping"}, map[string]Question{"ok": Noul("Is this a test?")})
	if err != nil {
		return 0, err
	}
	if _, ok := resp.Answers["ok"]; !ok {
		return 0, errors.New("jev: the answer is missing")
	}
	return time.Since(started), nil
}

// excerpt is an error body, short: FastAPI's {"detail": …} or the text.
func excerpt(data []byte) string {
	var v struct {
		Detail any `json:"detail"`
	}
	if json.Unmarshal(data, &v) == nil && v.Detail != nil {
		if s, ok := v.Detail.(string); ok {
			return s
		}
		b, _ := json.Marshal(v.Detail)
		data = b
	}
	s := strings.TrimSpace(string(data))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
