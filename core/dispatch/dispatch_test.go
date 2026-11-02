package dispatch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/yangxin0/dial/core/jev"
	"github.com/yangxin0/dial/core/protocol"
)

var apps = []protocol.App{
	{ID: "com.apple.finder", Name: "Finder", Running: true, Active: true},
	{ID: "com.apple.Safari", Name: "Safari", Running: true},
	{ID: "com.tinyspeck.slackmacgap", Name: "Slack", Running: true},
	{ID: "com.microsoft.VSCode", Name: "Visual Studio Code", Running: true},
	{ID: "com.apple.dt.Xcode", Name: "Xcode", Running: false},
}

func TestRules(t *testing.T) {
	cases := []struct {
		in     string
		intent string
		action Action
		app    string
	}{
		{"Switch to Safari.", Command, SwitchApp, "com.apple.Safari"},
		{"go to slack", Command, SwitchApp, "com.tinyspeck.slackmacgap"},
		{"切换到 Safari。", Command, SwitchApp, "com.apple.Safari"},
		{"open xcode", Command, OpenApp, "com.apple.dt.Xcode"},
		{"打开Xcode", Command, OpenApp, "com.apple.dt.Xcode"},
		{"switch to xcode", Command, OpenApp, "com.apple.dt.Xcode"},
		{"open code", Command, OpenApp, "com.microsoft.VSCode"},
		{"Scroll down.", Command, ScrollDown, ""},
		{"向下滚动", Command, ScrollDown, ""},
		{"往上", Command, ScrollUp, ""},
		{"page up", Command, ScrollUp, ""},
		{"go to the top", Command, PageTop, ""},
		{"回到顶部。", Command, PageTop, ""},
		{"bottom of the page", Command, PageBottom, ""},
		{"到底部", Command, PageBottom, ""},
		{"close the window", Command, CloseWindow, ""},
		{"关闭窗口", Command, CloseWindow, ""},
		{"I will be there in ten minutes.", Dictation, None, ""},
		{"今天下午开会。", Dictation, None, ""},
		{"", Dictation, None, ""},
	}
	for _, c := range cases {
		r := Rules(c.in, apps)
		if r.Intent != c.intent || r.Action != c.action || r.App != c.app {
			t.Errorf("%q: %s %s %q, want %s %s %q (%s)", c.in, r.Intent, r.Action, r.App, c.intent, c.action, c.app, r.Note)
		}
		if c.intent == Dictation && r.Text != c.in {
			t.Errorf("%q: text %q", c.in, r.Text)
		}
	}
	r := Rules("switch to photoshop", apps)
	if r.Intent != Command || r.Action != None || r.Note == "" {
		t.Errorf("unknown app: %+v", r)
	}
}

func TestQuestions(t *testing.T) {
	q, keys := Questions(apps)
	if len(q) != 3 || len(keys) != 5 || len(q["app"].Criteria) != 6 {
		t.Fatalf("questions %v keys %v", q, keys)
	}
	if keys["app_2"].ID != "com.apple.Safari" {
		t.Fatalf("keys %v", keys)
	}
}

func jevServer(t *testing.T, answers string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		json.NewDecoder(r.Body).Decode(&req)
		if _, ok := req["questions"].(map[string]any)["app"]; !ok {
			t.Errorf("no app question in %v", req)
		}
		w.Write([]byte(`{"model":"jev","answers":` + answers + `,"usage":{}}`))
	}))
}

func TestDecideWithJev(t *testing.T) {
	srv := jevServer(t, `{
		"intent":{"type":"choice","choice":"command","confidence":0.9,"probabilities":{"command":0.93,"dictation":0.07}},
		"action":{"type":"choice","choice":"switch_app","confidence":0.8,"probabilities":{"switch_app":0.85,"open_app":0.1,"none":0.05}},
		"app":{"type":"choice","choice":"app_3","confidence":0.9,"probabilities":{"app_3":0.9,"none":0.1}}}`)
	defer srv.Close()
	d := Decider{Jev: jev.Client{BaseURL: srv.URL, APIKey: "k"}}
	r := d.Decide(context.Background(), "jump over to slack please", apps)
	if r.Source != "jev" || r.Intent != Command || r.Action != SwitchApp || r.App != "com.tinyspeck.slackmacgap" || r.Confidence != 0.93 {
		t.Fatalf("%+v", r)
	}
}

func TestDecideDictationBelowThreshold(t *testing.T) {
	srv := jevServer(t, `{
		"intent":{"type":"choice","choice":"command","confidence":0.1,"probabilities":{"command":0.55,"dictation":0.45}},
		"action":{"type":"choice","choice":"none","probabilities":{"none":1}},
		"app":{"type":"choice","choice":"none","probabilities":{"none":1}}}`)
	defer srv.Close()
	d := Decider{Jev: jev.Client{BaseURL: srv.URL, APIKey: "k"}}
	r := d.Decide(context.Background(), "let's switch things up", apps)
	if r.Intent != Dictation || r.Text != "let's switch things up" {
		t.Fatalf("%+v", r)
	}
}

func TestDecideAppFallsBackToNameMatch(t *testing.T) {
	srv := jevServer(t, `{
		"intent":{"type":"choice","choice":"command","probabilities":{"command":0.9,"dictation":0.1}},
		"action":{"type":"choice","choice":"open_app","probabilities":{"open_app":0.9,"none":0.1}},
		"app":{"type":"choice","choice":"none","probabilities":{"none":0.6,"app_5":0.4}}}`)
	defer srv.Close()
	d := Decider{Jev: jev.Client{BaseURL: srv.URL, APIKey: "k"}}
	r := d.Decide(context.Background(), "open xcode", apps)
	if r.Action != OpenApp || r.App != "com.apple.dt.Xcode" {
		t.Fatalf("%+v", r)
	}
}

func TestDecideFallsBackToRulesWhenJevFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusBadGateway)
	}))
	defer srv.Close()
	d := Decider{Jev: jev.Client{BaseURL: srv.URL, APIKey: "k"}}
	r := d.Decide(context.Background(), "scroll down", apps)
	if r.Source != "rules" || r.Action != ScrollDown || r.Note == "" {
		t.Fatalf("%+v", r)
	}
}

func TestDecideWithoutJev(t *testing.T) {
	r := Decider{}.Decide(context.Background(), "hello world", apps)
	if r.Source != "rules" || r.Intent != Dictation {
		t.Fatalf("%+v", r)
	}
}
