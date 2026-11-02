package ring

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/yangxin0/dial/core/protocol"
)

func TestOrderLearnsAndFades(t *testing.T) {
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "ring.json")
	r, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	apps := []protocol.App{
		{ID: "finder", Name: "Finder", Running: true, Active: true},
		{ID: "safari", Name: "Safari", Running: true},
		{ID: "slack", Name: "Slack", Running: true},
		{ID: "xcode", Name: "Xcode", Running: false},
	}
	if got := r.Order(apps, 8, now); len(got) != 3 || got[0] != "finder" || got[2] != "slack" {
		t.Fatalf("fresh ring keeps the given order: %v", got)
	}
	r.Record("slack", "Slack", now)
	r.Record("slack", "Slack", now)
	r.Record("safari", "Safari", now)
	if got := r.Order(apps, 8, now); got[0] != "slack" || got[1] != "safari" || got[2] != "finder" {
		t.Fatalf("learned order: %v", got)
	}
	if err := r.Save(); err != nil {
		t.Fatal(err)
	}
	again, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.Order(apps, 8, now); got[0] != "slack" {
		t.Fatalf("saved order: %v", got)
	}
	// Six weeks on, Slack's two uses have faded below a fresh use of Finder.
	later := now.Add(42 * 24 * time.Hour)
	again.Record("finder", "Finder", later)
	if got := again.Order(apps, 8, later); got[0] != "finder" {
		t.Fatalf("faded order: %v", got)
	}
}

func TestOrderKeepsActiveWithinSize(t *testing.T) {
	now := time.Now()
	r, _ := Load("")
	var apps []protocol.App
	for _, id := range []string{"a", "b", "c", "d"} {
		apps = append(apps, protocol.App{ID: id, Name: id, Running: true})
		r.Record(id, id, now)
	}
	apps = append(apps, protocol.App{ID: "e", Name: "e", Running: true, Active: true})
	got := r.Order(apps, 3, now)
	if len(got) != 3 || got[2] != "e" {
		t.Fatalf("active app kept: %v", got)
	}
}
