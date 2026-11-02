// Package ring is the learned app ring: the apps the dial switches to,
// ordered by how often they are picked, the count fading with time so an
// app that fell out of use drifts to the back.
package ring

import (
	"encoding/json"
	"errors"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/yangxin0/dial/core/protocol"
)

const (
	DefaultHalfLifeDays = 14
	DefaultSize         = 8
)

// Entry is one app's use.
type Entry struct {
	Name  string    `json:"name"`
	Count float64   `json:"count"`
	Last  time.Time `json:"last"`
}

// Ring holds the counts, in a file of its own so Settings' edits to the
// config never touch it.
type Ring struct {
	path         string
	HalfLifeDays float64
	mu           sync.Mutex
	entries      map[string]Entry
}

// Load reads the file; a missing one is an empty ring.
func Load(path string) (*Ring, error) {
	r := &Ring{path: path, HalfLifeDays: DefaultHalfLifeDays, entries: map[string]Entry{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return r, err
	}
	var file struct {
		Apps map[string]Entry `json:"apps"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return r, err
	}
	if file.Apps != nil {
		r.entries = file.Apps
	}
	return r, nil
}

// Save writes the counts.
func (r *Ring) Save() error {
	if r.path == "" {
		return nil
	}
	r.mu.Lock()
	data, err := json.MarshalIndent(map[string]any{"apps": r.entries}, "", "  ")
	r.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return err
	}
	tmp := r.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.path)
}

// weight is an entry's count faded to now.
func (r *Ring) weight(e Entry, now time.Time) float64 {
	if e.Last.IsZero() || r.HalfLifeDays <= 0 {
		return e.Count
	}
	days := now.Sub(e.Last).Hours() / 24
	if days <= 0 {
		return e.Count
	}
	return e.Count * math.Pow(0.5, days/r.HalfLifeDays)
}

// Record is one switch to the app.
func (r *Ring) Record(id, name string, now time.Time) {
	if id == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	e := r.entries[id]
	e.Count = r.weight(e, now) + 1
	e.Last = now
	if name != "" {
		e.Name = name
	}
	r.entries[id] = e
}

// Reset forgets everything.
func (r *Ring) Reset() {
	r.mu.Lock()
	r.entries = map[string]Entry{}
	r.mu.Unlock()
}

// Entries is a copy of the counts, by id.
func (r *Ring) Entries() map[string]Entry {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]Entry, len(r.entries))
	for k, v := range r.entries {
		out[k] = v
	}
	return out
}

// Order is the ring: the running apps, most used first, the rest in the
// order given (the platform's most-recent-first), at most size of them.
// The active app is always on it.
func (r *Ring) Order(apps []protocol.App, size int, now time.Time) []string {
	if size <= 0 {
		size = DefaultSize
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	type ranked struct {
		id     string
		weight float64
		index  int
		active bool
	}
	var list []ranked
	for i, a := range apps {
		if !a.Running || a.ID == "" {
			continue
		}
		list = append(list, ranked{id: a.ID, weight: r.weight(r.entries[a.ID], now), index: i, active: a.Active})
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].weight != list[j].weight {
			return list[i].weight > list[j].weight
		}
		return list[i].index < list[j].index
	})
	if len(list) > size {
		// Keep the active app on the ring, in the last slot if it would
		// have fallen off.
		activeAt := -1
		for i, x := range list {
			if x.active {
				activeAt = i
				break
			}
		}
		if activeAt >= size {
			list[size-1] = list[activeAt]
		}
		list = list[:size]
	}
	out := make([]string, len(list))
	for i, x := range list {
		out[i] = x.id
	}
	return out
}
