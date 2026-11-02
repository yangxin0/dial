package config

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestLoadDefaultsAndTemplate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	c, err := Load(path)
	if err != nil || c.Port != 47831 || c.Ring.Size != 8 || c.CommandThreshold != 0.6 {
		t.Fatalf("defaults: %+v %v", c, err)
	}
	if ready := c.Ready(); ready["voice"] || ready["jev"] {
		t.Fatalf("ready %v", ready)
	}
	if err := Ensure(path); err != nil {
		t.Fatal(err)
	}
	// Windows has no Unix modes to check.
	if info, _ := os.Stat(path); runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	c, err = Load(path)
	if err != nil || len(c.Voice.Engines) != 1 || c.Voice.Engines[0].Name != "豆包" {
		t.Fatalf("template: %+v %v", c, err)
	}
	if _, ok := c.ActiveEngine(); !ok {
		t.Fatal("no active engine")
	}
	if err := Ensure(path); err != nil {
		t.Fatalf("ensure twice: %v", err)
	}
}

func TestLoadLenient(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"port":"nope","commandThreshold":7,"jev":{"apiKey":"k"},"voice":{"engines":[{"name":"a","apiKey":"x"},{"name":"b","apiKey":"y"}],"engine":"b"}}`), 0o600)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.Port != 47831 || c.CommandThreshold != 0.6 {
		t.Fatalf("lenient: %+v", c)
	}
	if e, _ := c.ActiveEngine(); e.Name != "b" {
		t.Fatalf("active %+v", e)
	}
	if !c.Ready()["jev"] || !c.Ready()["voice"] {
		t.Fatalf("ready %v", c.Ready())
	}
}
