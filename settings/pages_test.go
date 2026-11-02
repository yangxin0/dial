package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/yangxin0/dial/core/config"
)

// A temporary config, with both keys set and dial-core's port pointing nowhere,
// so nothing here depends on this machine.
func testHost(t *testing.T) *host {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DIAL_CONFIG_DIR", dir)
	data, err := json.Marshal(object{
		"voice":      object{"engines": []object{{"name": "test", "type": "volcengine", "apiKey": "k"}}, "engine": "test"},
		"jev":        object{"apiKey": "k"},
		"port":       1,
		"unknownKey": "keep me",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := config.Path(); got != filepath.Join(dir, "config.json") {
		t.Fatalf("config path %s", got)
	}
	return newHost("test-version")
}

func findChrome() string {
	if path := os.Getenv("CHROME"); path != "" {
		return path
	}
	if _, err := os.Stat("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"); err == nil {
		return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
	}
	for _, name := range []string{"google-chrome", "chromium", "chromium-browser"} {
		if path, err := exec.LookPath(name); err == nil {
			return path
		}
	}
	return ""
}

// Loads the real pages in a real browser, against the real API, and checks the
// script ran to the end. A syntax error once killed every script on the page
// and nothing noticed: the Go build embeds the file without reading it.
func TestPagesRunInARealBrowser(t *testing.T) {
	chrome := findChrome()
	if chrome == "" {
		if os.Getenv("DIAL_REQUIRE_BROWSER") != "" {
			t.Fatal("no Chrome here, and this run requires one")
		}
		t.Skip("no Chrome here, so the pages were not loaded")
	}
	pages, err := fs.Sub(assets, "assets")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(testHost(t).handler(pages))
	defer server.Close()

	profile, err := os.MkdirTemp("", "dial-settings-test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(profile)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
		"--user-data-dir="+profile, "--use-mock-keychain", "--password-store=basic",
		"--virtual-time-budget=5000", "--dump-dom", server.URL+"/")
	var dom strings.Builder
	cmd.Stdout = &dom
	if err := cmd.Run(); err != nil {
		t.Fatalf("chrome: %v", err)
	}
	page := dom.String()
	if !strings.Contains(page, "Get the dial ready") {
		t.Fatalf("the page didn't load: %.300s", page)
	}

	// Each of these is only true once the script has run and the API answered.
	checks := []struct{ name, pattern string }{
		{"the version from the API", `id="version">test-version<`},
		{"the speech engine is ticked", `id="chk-voice"[^>]*class="ok"|class="ok"[^>]*id="chk-voice"`},
		{"Jev is ticked", `id="chk-jev"[^>]*class="ok"|class="ok"[^>]*id="chk-jev"`},
		{"the config path from the API", `id="configPath"[^>]*>[^<]*config\.json<`},
		{"the permissions row was updated", `Open Dial: it reports its Accessibility and Microphone grants here\.`},
	}
	for _, check := range checks {
		if !regexp.MustCompile(check.pattern).MatchString(page) {
			t.Errorf("%s: the page's script didn't get there (looked for %s)", check.name, check.pattern)
		}
	}
	// With dial-core's port pointing nowhere, this one must stay unticked.
	if regexp.MustCompile(`id="chk-core"[^>]*class="ok"|class="ok"[^>]*id="chk-core"`).MatchString(page) {
		t.Errorf("dial-core is ticked with nothing running")
	}
}

func TestConfigSetKeepsWhatItDoesntKnow(t *testing.T) {
	h := testHost(t)
	ctx := context.Background()
	if _, err := h.call(ctx, "config.set", object{"key": "commandThreshold", "value": 0.8}); err != nil {
		t.Fatal(err)
	}
	reply, err := h.call(ctx, "config.get", object{})
	if err != nil {
		t.Fatal(err)
	}
	values := reply.(object)
	if values["commandThreshold"] != 0.8 {
		t.Errorf("threshold %v", values["commandThreshold"])
	}
	if values["unknownKey"] != "keep me" {
		t.Errorf("an edit lost a key it doesn't know: %v", values)
	}
	if info, err := os.Stat(h.path); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("the config holds keys, so it must stay private: %v %v", info, err)
	}
}

func TestConfigSetRefusesUnknownKeysAndOps(t *testing.T) {
	h := testHost(t)
	ctx := context.Background()
	if _, err := h.call(ctx, "config.set", object{"key": "nonsense", "value": 1}); err == nil {
		t.Error("set an unknown key")
	}
	if _, err := h.call(ctx, "no.such.op", object{}); err == nil {
		t.Error("ran an unknown op")
	}
	if _, err := h.call(ctx, "open", object{"what": "/etc/passwd"}); err == nil {
		t.Error("opened an arbitrary path")
	}
}

func TestStatusReportsWhatIsSetUp(t *testing.T) {
	reply, err := testHost(t).call(context.Background(), "status", object{})
	if err != nil {
		t.Fatal(err)
	}
	status := reply.(object)
	if status["voice"] != true || status["jev"] != true {
		t.Errorf("status %v", status)
	}
	if core := status["core"].(object); core["running"] != false {
		t.Errorf("core %v", core)
	}
}
