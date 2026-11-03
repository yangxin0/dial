package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
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
		"theme":      object{"size": 1.5, "transparency": 0.25, "ringStyle": "spokes"},
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

// The real pages in a real browser against the real API, as the DOM stands once
// the script has run. An extra script, if any, runs after the page's own: it
// drives the page with real events, and whatever it puts in #testOut can be read
// back with testOutput.
func browse(t *testing.T, h *host, script string) string {
	t.Helper()
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
	handler := h.handler(pages)
	if script != "" {
		index, err := fs.ReadFile(pages, "index.html")
		if err != nil {
			t.Fatal(err)
		}
		driven := strings.Replace(string(index), "</body>", `<pre id="testOut"></pre><script type="module">
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const say = (x) => { document.getElementById("testOut").textContent += x + "\n"; };
const type = (el, text) => { el.focus(); el.value = text; el.dispatchEvent(new Event("input", { bubbles: true })); };
await wait(300);
`+script+`
</script></body>`, 1)
		inner := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" {
				w.Header().Set("Content-Type", "text/html")
				io.WriteString(w, driven)
				return
			}
			inner.ServeHTTP(w, r)
		})
	}
	server := httptest.NewServer(handler)
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
		"--virtual-time-budget=9000", "--dump-dom", server.URL+"/")
	var dom strings.Builder
	cmd.Stdout = &dom
	if err := cmd.Run(); err != nil {
		t.Fatalf("chrome: %v", err)
	}
	page := dom.String()
	if !strings.Contains(page, `id="setupTitle"`) {
		t.Fatalf("the page didn't load: %.300s", page)
	}
	return page
}

func testOutput(page string) []string {
	m := regexp.MustCompile(`(?s)<pre id="testOut">(.*?)</pre>`).FindStringSubmatch(page)
	if m == nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(html.UnescapeString(m[1])), "\n")
}

// A host with this config, whatever it is.
func hostWithConfig(t *testing.T, values object) *host {
	t.Helper()
	data, err := json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	return hostWithFile(t, data)
}

func hostWithFile(t *testing.T, data []byte) *host {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DIAL_CONFIG_DIR", dir)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return newHost("test-version")
}

// A dial-core that answers a hello with this dial, so the Setup page sees it.
func fakeCore(t *testing.T, dial protocol.DialStatus) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				if _, err := bufio.NewReader(conn).ReadBytes('\n'); err != nil {
					return
				}
				b, _ := json.Marshal(protocol.Message{Type: protocol.Hello, Version: "test", Dial: &dial})
				conn.Write(append(b, '\n'))
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func stepHas(page, step, class string) bool {
	return regexp.MustCompile(`id="` + step + `" class="[^"]*\b` + class + `\b`).MatchString(page)
}

// The steps there are to finish on this platform.
func requiredSteps() int {
	if runtime.GOOS == "darwin" {
		return 3
	}
	return 2
}

// Loads the real pages and checks the script ran to the end. A syntax error once
// killed every script on the page and nothing noticed: the Go build embeds the
// file without reading it.
func TestPagesRunInARealBrowser(t *testing.T) {
	page := browse(t, testHost(t), "")

	// Each of these is only true once the script has run and the API answered.
	checks := []struct{ name, pattern string }{
		{"the version from the API", `id="version">test-version<`},
		{"the speech engine is ticked", `id="step-voice" class="[^"]*\bdone\b`},
		{"Jev is ticked", `id="step-jev" class="[^"]*\bdone\b`},
		{"the next step is opening the dial", `id="step-dial" class="[^"]*\bcurrent\b`},
		{"the config path from the API", `id="configPath"[^>]*>[^<]*config\.json<`},
		{"the speech key on Get started", `id="quickVoiceKey"[^>]*>`},
		{"the theme's size from the config", `id="themeSizeValue">150%<`},
		{"the theme's transparency from the config", `id="themeTransparencyValue">25%<`},
		{"the ring style from the config", `data-style="spokes" aria-checked="true"`},
	}
	for _, check := range checks {
		if !regexp.MustCompile(check.pattern).MatchString(page) {
			t.Errorf("%s: the page's script didn't get there (looked for %s)", check.name, check.pattern)
		}
	}
	// Every style the core knows can be chosen, and just one is.
	for _, style := range []string{protocol.RingStyleTicksAndDimple, protocol.RingStyleTicks, protocol.RingStyleDimple, protocol.RingStyleSpokes, protocol.RingStyleTrail} {
		if !strings.Contains(page, `data-style="`+style+`"`) {
			t.Errorf("the Theme tab has no ring style %s", style)
		}
	}
	if n := len(regexp.MustCompile(`data-style="[^"]*" aria-checked="true"`).FindAllString(page, -1)); n != 1 {
		t.Errorf("%d ring styles are chosen", n)
	}
	// With dial-core's port pointing nowhere, this one must stay unticked.
	if stepHas(page, "step-dial", "done") {
		t.Errorf("the dial is ticked with nothing running")
	}
}

// What someone sees the very first time: nothing set up, and one thing to do.
func TestFirstLaunchShowsOneNextStep(t *testing.T) {
	page := browse(t, hostWithConfig(t, object{"port": 1}), "")
	if !strings.Contains(page, `id="setupTitle">Set up Dial<`) {
		t.Errorf("the title isn't the setup one")
	}
	if !stepHas(page, "step-dial", "current") || !stepHas(page, "step-dial", "open") {
		t.Errorf("opening the dial should be the open next step")
	}
	for _, step := range []string{"step-permissions", "step-voice"} {
		if stepHas(page, step, "current") || stepHas(page, step, "open") || stepHas(page, step, "done") {
			t.Errorf("%s should wait its turn", step)
		}
	}
	want := fmt.Sprintf(`>0/%d<`, requiredSteps())
	if !regexp.MustCompile(`id="navProgress"[^>]*` + want).MatchString(page) {
		t.Errorf("the sidebar should say %s", want)
	}
	if tag := regexp.MustCompile(`<span[^>]*id="navVoice"[^>]*>`).FindString(page); tag == "" || strings.Contains(tag, "hidden") {
		t.Errorf("Voice should be marked as missing its key: %q", tag)
	}
}

// The guide follows what the dial reports, a step at a time.
func TestSetupMovesOnAsTheDialReports(t *testing.T) {
	missing := fakeCore(t, protocol.DialStatus{Connected: true, Platform: "macos", Accessibility: false, Microphone: true})
	page := browse(t, hostWithConfig(t, object{"port": missing}), "")
	if !stepHas(page, "step-dial", "done") {
		t.Errorf("the dial is connected, so opening it is done")
	}
	if runtime.GOOS == "darwin" {
		if !stepHas(page, "step-permissions", "current") {
			t.Errorf("permissions should be next")
		}
		if !regexp.MustCompile(`id="perm-microphone" class="[^"]*\bdone\b`).MatchString(page) {
			t.Errorf("the microphone is allowed, so it should be ticked")
		}
		if regexp.MustCompile(`id="perm-accessibility" class="[^"]*\bdone\b`).MatchString(page) {
			t.Errorf("Accessibility isn't allowed, so it shouldn't be ticked")
		}
		if regexp.MustCompile(`id="permStale"[^>]*hidden`).MatchString(page) {
			t.Errorf("the help for a stale Accessibility entry should show")
		}
	}

	allowed := fakeCore(t, protocol.DialStatus{Connected: true, Platform: "macos", Accessibility: true, Microphone: true})
	page = browse(t, hostWithConfig(t, object{"port": allowed}), "")
	if !stepHas(page, "step-voice", "current") {
		t.Errorf("the speech key should be next once the dial is up and allowed")
	}

	page = browse(t, hostWithConfig(t, object{"port": allowed,
		"voice": object{"engines": []object{{"name": "test", "type": "volcengine", "apiKey": "k"}}, "engine": "test"}}), "")
	if !strings.Contains(page, `id="setupTitle">You're all set<`) && !strings.Contains(page, `id="setupTitle">You&#39;re all set<`) {
		t.Errorf("everything required is done, so it should say so")
	}
	if regexp.MustCompile(`class="step[^"]*\bcurrent\b`).MatchString(page) {
		t.Errorf("there should be no next step left")
	}
	if !regexp.MustCompile(`id="navProgress"[^>]*hidden`).MatchString(page) {
		t.Errorf("the sidebar's progress should be gone")
	}
	if !stepHas(page, "step-jev", "open") {
		t.Errorf("Jev, being optional and not set up, should now be offered")
	}
}

// A mistake in the file once left the whole window blank: the script stopped at
// its first read. It must say what's wrong, keep working, and leave the file be.
func TestABrokenConfigIsExplainedAndNotOverwritten(t *testing.T) {
	broken := []byte("{ this is not JSON")
	h := hostWithFile(t, broken)
	// Just loaded, with nothing touched: typing would refresh the status too,
	// and once hid a page that had stopped.
	page := browse(t, h, "")
	if regexp.MustCompile(`id="problem"[^>]*hidden`).MatchString(page) {
		t.Errorf("the problem banner should show")
	}
	if !regexp.MustCompile(`id="problemText">[^<]+<`).MatchString(page) {
		t.Errorf("the banner should say what's wrong")
	}
	if !strings.Contains(page, `id="version">test-version<`) {
		t.Errorf("the page should carry on: %.200s", page)
	}
	page = browse(t, h, `
type(document.getElementById("hotwords"), "anything");
await wait(700);
say(document.getElementById("saveState").textContent);
`)
	if out := testOutput(page); len(out) == 0 || !strings.HasPrefix(out[0], "Couldn't save") {
		t.Errorf("a failed save should say so, got %q", out)
	}
	if data, _ := os.ReadFile(h.path); string(data) != string(broken) {
		t.Errorf("the broken file was changed to %q", data)
	}
}

// Pasting a key on Get started saves it where the core reads it, and the Voice
// page shows the same key.
func TestAKeyPastedOnGetStartedIsSaved(t *testing.T) {
	h := hostWithConfig(t, object{"port": 1, "unknownKey": "keep me"})
	page := browse(t, h, `
type(document.getElementById("quickVoiceKey"), " pasted-key ");
await wait(700);
say(document.querySelector('#engine [data-field="apiKey"]').value);
say(document.getElementById("saveState").textContent);
type(document.getElementById("quickJevKey"), "jev-key");
await wait(700);
say(document.querySelector('#jevForm [data-field="apiKey"]').value);
`)
	out := testOutput(page)
	if len(out) != 3 || strings.TrimSpace(out[0]) != "pasted-key" || out[1] != "Saved" || out[2] != "jev-key" {
		t.Errorf("the pages said %q", out)
	}
	cfg, err := config.Load(h.path)
	if err != nil {
		t.Fatal(err)
	}
	if ready := cfg.Ready(); !ready["voice"] || !ready["jev"] {
		t.Errorf("the core would see %v", ready)
	}
	raw, err := h.raw()
	if err != nil {
		t.Fatal(err)
	}
	if raw["unknownKey"] != "keep me" {
		t.Errorf("an unknown key was lost: %v", raw)
	}
}

// The core prefers an API key, so choosing the App ID and token must not leave
// one behind in the file, and the page must open on the way that's in use.
func TestChoosingAppIDAndTokenSavesWithoutTheKey(t *testing.T) {
	h := hostWithConfig(t, object{"port": 1,
		"voice": object{"engines": []object{{"name": "test", "type": "volcengine", "apiKey": "old-key"}}, "engine": "test"}})
	browse(t, h, `
document.querySelector('#credMode [data-cred="token"]').click();
type(document.querySelector('#engine [data-field="appId"]'), "my-app");
type(document.querySelector('#engine [data-field="accessToken"]'), "my-token");
await wait(700);
`)
	cfg, err := config.Load(h.path)
	if err != nil {
		t.Fatal(err)
	}
	e, ok := cfg.ActiveEngine()
	if !ok || e.APIKey != "" || e.AppID != "my-app" || e.AccessToken != "my-token" {
		t.Errorf("the core would use %+v", e)
	}
	page := browse(t, h, "")
	if !regexp.MustCompile(`data-cred="token" aria-checked="true"`).MatchString(page) {
		t.Errorf("the Voice page should open on the App ID and token")
	}
}

func TestEveryPageOpens(t *testing.T) {
	page := browse(t, testHost(t), `
for (const b of document.querySelectorAll("#nav button")) {
  b.click();
  await wait(50);
  const on = document.querySelectorAll(".view.on");
  say(b.dataset.view + " " + on.length + " " + on[0].id + " " + b.getAttribute("aria-current"));
}
`)
	want := []string{"setup", "voice", "jev", "ring", "theme", "about"}
	out := testOutput(page)
	if len(out) != len(want) {
		t.Fatalf("the pages said %q", out)
	}
	for i, view := range want {
		if out[i] != view+" 1 "+view+" page" {
			t.Errorf("page %s: %q", view, out[i])
		}
	}
}

// What the dial would do reads as words, with the plain rules when there's no Jev.
func TestTryingASentenceSaysWhatTheDialWouldDo(t *testing.T) {
	page := browse(t, hostWithConfig(t, object{"port": 1}), `
for (const chip of document.querySelectorAll("#tryChips button")) {
  chip.click();
  await wait(400);
  say(document.getElementById("tryWhat").textContent + " | " + document.getElementById("tryWhy").textContent);
}
`)
	out := testOutput(page)
	if len(out) != 4 {
		t.Fatalf("the page said %q", out)
	}
	for i, want := range []string{"Switch to Safari", "Scroll down", "Close the window", "Type “see you at three tomorrow”"} {
		if !strings.HasPrefix(out[i], want+" | Plain rules decided") {
			t.Errorf("chip %d: %q, want %q", i, out[i], want)
		}
	}
}

// Forgetting what the ring learned can't be undone, so one click mustn't do it.
func TestForgettingTheRingTakesTwoClicks(t *testing.T) {
	entries := func(h *host) int {
		r, err := ring.Load(config.RingPath())
		if err != nil {
			t.Fatal(err)
		}
		return len(r.Entries())
	}
	h := hostWithConfig(t, object{"port": 1})
	r, err := ring.Load(config.RingPath())
	if err != nil {
		t.Fatal(err)
	}
	r.Record("com.example.app", "Example", time.Now())
	if err := r.Save(); err != nil {
		t.Fatal(err)
	}
	open := `document.querySelector('#nav [data-view="ring"]').click(); await wait(300);`
	page := browse(t, h, open+`
say(document.querySelector("#learned .name").textContent);
document.getElementById("ringReset").click();
await wait(300);
say(document.getElementById("ringReset").textContent);
`)
	out := testOutput(page)
	if len(out) != 2 || out[0] != "Example" || out[1] != "Forget 1 app" {
		t.Errorf("the page said %q", out)
	}
	if entries(h) != 1 {
		t.Errorf("one click forgot the ring")
	}
	browse(t, h, open+`
document.getElementById("ringReset").click();
await wait(100);
document.getElementById("ringReset").click();
await wait(300);
`)
	if entries(h) != 0 {
		t.Errorf("two clicks should forget it")
	}
}

func TestTheDialIsFoundBesideSettings(t *testing.T) {
	dir := t.TempDir()
	mac := filepath.Join(dir, "Dial Settings.app", "Contents", "MacOS", "Dial Settings")
	if got := dialBeside(mac, "darwin"); got != "" {
		t.Errorf("found %q with no dial there", got)
	}
	if err := os.MkdirAll(filepath.Join(dir, "Dial Settings.app", "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "Dial.app"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := dialBeside(mac, "darwin"); got != filepath.Join(dir, "Dial.app") {
		t.Errorf("found %q", got)
	}
	win := filepath.Join(dir, "dial-settings.exe")
	if got := dialBeside(win, "windows"); got != "" {
		t.Errorf("found %q with no dial.exe there", got)
	}
	if err := os.WriteFile(filepath.Join(dir, "dial.exe"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := dialBeside(win, "windows"); got != filepath.Join(dir, "dial.exe") {
		t.Errorf("found %q", got)
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

func TestThemeCanBeSaved(t *testing.T) {
	h := testHost(t)
	ctx := context.Background()
	if _, err := h.call(ctx, "config.set", object{"key": "theme", "value": object{"size": 2.5, "transparency": 0.5, "ringStyle": "trail"}}); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(h.path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Theme.Size != 2.5 || cfg.Theme.Transparency != 0.5 || cfg.Theme.RingStyle != "trail" {
		t.Errorf("the core would read %+v", cfg.Theme)
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
