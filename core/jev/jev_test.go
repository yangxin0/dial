package jev

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestURL(t *testing.T) {
	for base, want := range map[string]string{
		"":                                    "https://api.typesafe.ai/v1/systemone",
		"https://api.typesafe.ai":             "https://api.typesafe.ai/v1/systemone",
		"https://api.typesafe.ai/v1/":         "https://api.typesafe.ai/v1/systemone",
		"https://gw.example.com/v1/systemone": "https://gw.example.com/v1/systemone",
	} {
		if got := (Client{BaseURL: base}).URL(); got != want {
			t.Errorf("%q: %q, want %q", base, got, want)
		}
	}
}

func TestAsk(t *testing.T) {
	var seen map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer k" {
			http.Error(w, `{"detail":"no key"}`, http.StatusUnauthorized)
			return
		}
		json.NewDecoder(r.Body).Decode(&seen)
		w.Write([]byte(`{"model":"jev-1.14.0","answers":{"intent":{"type":"choice","choice":"command","confidence":0.9,"probabilities":{"command":0.95,"dictation":0.05}}},"usage":{"input_tokens":10,"output_tokens":1}}`))
	}))
	defer srv.Close()
	c := Client{BaseURL: srv.URL, APIKey: "k"}
	resp, err := c.Ask(context.Background(), map[string]any{"transcript": "open safari"},
		map[string]Question{"intent": Choice("Command or dictation?", map[string]string{"command": "a command", "dictation": "text"})})
	if err != nil {
		t.Fatal(err)
	}
	if a := resp.Answers["intent"]; a.Choice != "command" || a.P("command") != 0.95 {
		t.Fatalf("answer %+v", a)
	}
	if seen["model"] != DefaultModel || seen["state"].(map[string]any)["transcript"] != "open safari" {
		t.Fatalf("request %v", seen)
	}
	if _, err := (Client{BaseURL: srv.URL, APIKey: "wrong"}).Ask(context.Background(), "x", nil); err == nil || err.Error() != "jev: HTTP 401 no key" {
		t.Fatalf("refused: %v", err)
	}
	if _, err := (Client{}).Ask(context.Background(), "x", nil); err == nil {
		t.Fatal("no key")
	}
}
