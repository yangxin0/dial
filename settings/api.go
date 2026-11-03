package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/yangxin0/dial/core/asr"
	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/jev"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
)

// The pages talk to the app over a small JSON API served next to them:
// `await dial(op, args)` in app.js is a POST to /api/<op>.

const (
	repository = "https://github.com/yangxin0/dial"
	// Where the speech keys come from: an API key from the new console, an App
	// ID and token from the old one.
	volcengineConsole    = "https://console.volcengine.com/speech/new/"
	volcengineOldConsole = "https://console.volcengine.com/speech/app"
	typesafeKeys         = "https://console.typesafe.ai/keys"
)

type object = map[string]any

type host struct {
	version string
	path    string
}

func newHost(version string) *host {
	return &host{version: version, path: config.Path()}
}

func (h *host) handler(pages fs.FS) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(pages))
	mux.HandleFunc("POST /api/{op}", func(w http.ResponseWriter, r *http.Request) {
		var args object
		json.NewDecoder(r.Body).Decode(&args)
		reply, err := h.call(r.Context(), r.PathValue("op"), args)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(reply)
	})
	return mux
}

// editableKeys are the top-level keys the pages may set.
var editableKeys = map[string]bool{
	"voice": true, "jev": true, "commandThreshold": true, "appThreshold": true, "port": true, "ring": true, "theme": true,
}

func (h *host) call(ctx context.Context, op string, args object) (any, error) {
	switch op {
	case "status":
		return h.status(ctx), nil
	case "config.get":
		config.Ensure(h.path)
		raw, err := h.raw()
		if err != nil {
			return nil, err
		}
		return raw, nil
	case "config.set":
		key, _ := args["key"].(string)
		if !editableKeys[key] {
			return nil, errors.New("unknown key " + key)
		}
		if err := h.set(key, args["value"]); err != nil {
			return object{"ok": false, "error": err.Error()}, nil
		}
		return object{"ok": true}, nil
	case "voice.test":
		m, _ := args["engine"].(map[string]any)
		var e asr.Engine
		b, _ := json.Marshal(m)
		json.Unmarshal(b, &e)
		took, logid, err := asr.Test(ctx, e)
		if err != nil {
			return object{"ok": false, "error": err.Error(), "logid": logid}, nil
		}
		return object{"ok": true, "ms": took.Milliseconds(), "logid": logid}, nil
	case "jev.test":
		m, _ := args["jev"].(map[string]any)
		c := jev.Client{}
		c.APIKey, _ = m["apiKey"].(string)
		c.BaseURL, _ = m["baseURL"].(string)
		c.Model, _ = m["model"].(string)
		took, err := c.Test(ctx)
		if err != nil {
			return object{"ok": false, "error": err.Error()}, nil
		}
		return object{"ok": true, "ms": took.Milliseconds()}, nil
	case "decide.try":
		text, _ := args["text"].(string)
		cfg, _ := config.Load(h.path)
		apps := []protocol.App{}
		for _, n := range []string{"Finder", "Safari", "Slack", "Visual Studio Code", "Terminal"} {
			apps = append(apps, protocol.App{ID: strings.ToLower(n), Name: n, Running: true})
		}
		ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
		defer cancel()
		result := cfg.Decider().Decide(ctx, text, apps)
		return result.Message(), nil
	case "ring.get":
		return h.ring()
	case "ring.reset":
		r, err := ring.Load(config.RingPath())
		if err != nil {
			return nil, err
		}
		r.Reset()
		if err := r.Save(); err != nil {
			return nil, err
		}
		return h.ring()
	case "open":
		var target string
		switch args["what"] {
		case "dial":
			return object{"ok": openDial() == nil}, nil
		case "volcengine":
			target = volcengineConsole
		case "volcengineOld":
			target = volcengineOldConsole
		case "typesafe":
			target = typesafeKeys
		case "config":
			config.Ensure(h.path)
			target = h.path
		case "repository":
			target = repository
		case "accessibility":
			target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
		case "microphone":
			target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
		default:
			return nil, errors.New("unknown target")
		}
		return object{"ok": open(target) == nil}, nil
	}
	return nil, errors.New("unknown op " + op)
}

func open(target string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", target).Run()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", target).Run()
	default:
		return exec.Command("xdg-open", target).Run()
	}
}

// dialBeside is the dial next to this app, as a build or an install puts them,
// or "" if it isn't there.
func dialBeside(executable, goos string) string {
	var path string
	switch goos {
	case "darwin":
		// …/Dial Settings.app/Contents/MacOS/Dial Settings
		path = filepath.Join(filepath.Dir(executable), "..", "..", "..", "Dial.app")
	case "windows":
		path = filepath.Join(filepath.Dir(executable), "dial.exe")
	default:
		return ""
	}
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	return path
}

func openDial() error {
	executable, err := os.Executable()
	if err == nil {
		if path := dialBeside(executable, runtime.GOOS); path != "" {
			return open(path)
		}
	}
	if runtime.GOOS == "darwin" {
		return exec.Command("open", "-b", "com.yangxin.dial").Run()
	}
	return errors.New("dial not found")
}

// raw is the file as it is, a map, so unknown keys survive an edit.
func (h *host) raw() (object, error) {
	data, err := os.ReadFile(h.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return object{}, nil
		}
		return nil, err
	}
	var values object
	if err := json.Unmarshal(data, &values); err != nil {
		return nil, fmt.Errorf("the config file is not JSON: %w", err)
	}
	if values == nil {
		values = object{}
	}
	return values, nil
}

func (h *host) set(key string, value any) error {
	config.Ensure(h.path)
	values, err := h.raw()
	if err != nil {
		return err
	}
	values[key] = value
	data, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		return err
	}
	tmp := h.path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, h.path)
}

func (h *host) ring() (any, error) {
	cfg, _ := config.Load(h.path)
	r, err := ring.Load(config.RingPath())
	if err != nil {
		return nil, err
	}
	r.HalfLifeDays = cfg.Ring.HalfLifeDays
	entries := r.Entries()
	type row struct {
		ID    string  `json:"id"`
		Name  string  `json:"name"`
		Count float64 `json:"count"`
		Last  string  `json:"last"`
	}
	rows := []row{}
	for id, e := range entries {
		rows = append(rows, row{ID: id, Name: e.Name, Count: e.Count, Last: e.Last.Local().Format("2006-01-02 15:04")})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Count > rows[j].Count })
	return object{"apps": rows}, nil
}

// status is the Setup page's checklist: the config, what is set up, and
// whether dial-core answers on its port.
func (h *host) status(ctx context.Context) object {
	cfg, loadErr := config.Load(h.path)
	ready := cfg.Ready()
	core := object{"running": false}
	dial := protocol.DialStatus{}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var d net.Dialer
	if conn, err := d.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", cfg.Port)); err == nil {
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(2 * time.Second))
		b, _ := json.Marshal(protocol.Message{Type: protocol.Hello, Platform: "settings", Version: h.version})
		conn.Write(append(b, '\n'))
		if line, err := bufio.NewReader(conn).ReadBytes('\n'); err == nil {
			var m protocol.Message
			if json.Unmarshal(line, &m) == nil && m.Type == protocol.Hello {
				core = object{"running": true, "version": m.Version}
				if m.Dial != nil {
					dial = *m.Dial
				}
			}
		}
	}
	problem := ""
	if loadErr != nil {
		problem = loadErr.Error()
	}
	return object{
		"version": h.version, "os": runtime.GOOS, "config": h.path, "problem": problem,
		"voice": ready["voice"], "jev": ready["jev"], "port": cfg.Port, "core": core, "dial": dial,
	}
}
