// Package config is the dial's config file: the speech engine, Jev, the
// thresholds and the ring's size. Settings edits it one key at a time;
// the core reads it afresh for every recording, so an edit applies at
// once.
package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/yangxin0/dial/core/asr"
	"github.com/yangxin0/dial/core/dispatch"
	"github.com/yangxin0/dial/core/jev"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
)

// Voice is the speech side: the engines, which is in use, and words to
// favor.
type Voice struct {
	Engines []asr.Engine `json:"engines"`
	// Engine is the name of the engine in use; else the first.
	Engine   string   `json:"engine"`
	Hotwords []string `json:"hotwords"`
}

// Jev is the decision side.
type Jev struct {
	APIKey  string `json:"apiKey"`
	BaseURL string `json:"baseURL"`
	Model   string `json:"model"`
}

// Ring is the learned ring's shape.
type Ring struct {
	Size         int     `json:"size"`
	HalfLifeDays float64 `json:"halfLifeDays"`
}

// Config is the file.
type Config struct {
	Voice Voice `json:"voice"`
	Jev   Jev   `json:"jev"`
	// CommandThreshold is how sure Jev must be of a command before the
	// dial runs one instead of typing the words.
	CommandThreshold float64 `json:"commandThreshold"`
	// AppThreshold is how sure Jev must be of the app named.
	AppThreshold float64 `json:"appThreshold"`
	Port         int     `json:"port"`
	Ring         Ring    `json:"ring"`
}

// Default is a config with nothing set up.
func Default() *Config {
	return &Config{
		Jev:              Jev{BaseURL: jev.DefaultBaseURL, Model: jev.DefaultModel},
		CommandThreshold: dispatch.DefaultCommandThreshold,
		AppThreshold:     dispatch.DefaultAppThreshold,
		Port:             protocol.DefaultPort,
		Ring:             Ring{Size: ring.DefaultSize, HalfLifeDays: ring.DefaultHalfLifeDays},
	}
}

// Template is the starter file.
const Template = `{
  "voice": {
    "engines": [
      {"name": "豆包", "type": "volcengine", "apiKey": "", "appId": "", "accessToken": "", "resourceId": "volc.seedasr.sauc.duration"}
    ],
    "engine": "豆包",
    "hotwords": []
  },
  "jev": {"apiKey": "", "baseURL": "https://api.typesafe.ai/v1", "model": "jev-latest"},
  "commandThreshold": 0.6,
  "appThreshold": 0.5,
  "port": 47831,
  "ring": {"size": 8, "halfLifeDays": 14}
}
`

// Dir is where the files live: ~/.config/dial, or %AppData%\dial on
// Windows. DIAL_CONFIG_DIR overrides it.
func Dir() string {
	if dir := os.Getenv("DIAL_CONFIG_DIR"); dir != "" {
		return dir
	}
	if runtime.GOOS == "windows" {
		if dir, err := os.UserConfigDir(); err == nil {
			return filepath.Join(dir, "dial")
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "dial")
}

// Path is the config file.
func Path() string { return filepath.Join(Dir(), "config.json") }

// RingPath is the learned ring's file.
func RingPath() string { return filepath.Join(Dir(), "ring.json") }

// Ensure writes the starter file when there is none, readable by the user
// only: it will hold keys.
func Ensure(path string) error {
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(Template), 0o600)
}

// Load reads the file; a missing one is the default. A field of the
// wrong type is left at its default.
func Load(path string) (*Config, error) {
	c := Default()
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return c, err
	}
	field := func(key string, into any) {
		if v, ok := raw[key]; ok {
			json.Unmarshal(v, into)
		}
	}
	field("voice", &c.Voice)
	field("jev", &c.Jev)
	field("commandThreshold", &c.CommandThreshold)
	field("appThreshold", &c.AppThreshold)
	field("port", &c.Port)
	field("ring", &c.Ring)
	if c.Port <= 0 || c.Port > 65535 {
		c.Port = protocol.DefaultPort
	}
	if c.Ring.Size <= 0 {
		c.Ring.Size = ring.DefaultSize
	}
	if c.Ring.HalfLifeDays <= 0 {
		c.Ring.HalfLifeDays = ring.DefaultHalfLifeDays
	}
	if c.CommandThreshold <= 0 || c.CommandThreshold > 1 {
		c.CommandThreshold = dispatch.DefaultCommandThreshold
	}
	if c.AppThreshold <= 0 || c.AppThreshold > 1 {
		c.AppThreshold = dispatch.DefaultAppThreshold
	}
	return c, nil
}

// ActiveEngine is the engine in use: the one named, else the first.
func (c *Config) ActiveEngine() (asr.Engine, bool) {
	name := strings.TrimSpace(c.Voice.Engine)
	for _, e := range c.Voice.Engines {
		if strings.TrimSpace(e.Name) == name && name != "" {
			return e.Normalized(), true
		}
	}
	if len(c.Voice.Engines) > 0 {
		return c.Voice.Engines[0].Normalized(), true
	}
	return asr.Engine{}, false
}

// JevClient is the client the config describes.
func (c *Config) JevClient() jev.Client {
	return jev.Client{BaseURL: c.Jev.BaseURL, APIKey: c.Jev.APIKey, Model: c.Jev.Model}
}

// Decider is the decider the config describes.
func (c *Config) Decider() dispatch.Decider {
	return dispatch.Decider{Jev: c.JevClient(), CommandThreshold: c.CommandThreshold, AppThreshold: c.AppThreshold}
}

// Ready says what is set up, for the dial's Hello.
func (c *Config) Ready() map[string]bool {
	e, ok := c.ActiveEngine()
	return map[string]bool{"voice": ok && e.Configured(), "jev": c.JevClient().Configured()}
}
