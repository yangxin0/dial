package server

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/yangxin0/dial/core/asr"
	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/dispatch"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
)

// fakeRecognizer hears what it is told to, when Finish arrives.
type fakeRecognizer struct {
	events chan asr.Event
	heard  []string
	got    int
	closed bool
}

func (f *fakeRecognizer) Send(pcm []byte) error { f.got += len(pcm); return nil }
func (f *fakeRecognizer) Finish([]byte) error {
	for i, h := range f.heard {
		f.events <- asr.Event{Text: h, Final: i == len(f.heard)-1}
	}
	close(f.events)
	return nil
}
func (f *fakeRecognizer) Events() <-chan asr.Event { return f.events }
func (f *fakeRecognizer) Close() {
	if !f.closed {
		f.closed = true
		close(f.events)
	}
}

type client struct {
	conn net.Conn
	r    *bufio.Reader
	t    *testing.T
}

func (c client) send(m protocol.Message) {
	b, _ := json.Marshal(m)
	c.conn.Write(append(b, '\n'))
}

func (c client) next() protocol.Message {
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		c.t.Fatalf("read: %v", err)
	}
	var m protocol.Message
	json.Unmarshal(line, &m)
	return m
}

func (c client) expect(kind string) protocol.Message {
	for {
		m := c.next()
		if m.Type == kind {
			return m
		}
		if m.Type == protocol.Error {
			c.t.Fatalf("error while waiting for %s: %s", kind, m.Message)
		}
	}
}

type fixture struct {
	client
	fake     *fakeRecognizer
	hotwords []string
}

func setup(t *testing.T, heard []string) (client, *fakeRecognizer) {
	f := setupFixture(t, heard)
	return f.client, f.fake
}

func setupFixture(t *testing.T, heard []string) *fixture {
	fake := &fakeRecognizer{events: make(chan asr.Event, 8), heard: heard}
	f := &fixture{fake: fake}
	cfg := config.Default()
	cfg.Voice.Engines = []asr.Engine{{Name: "fake", APIKey: "k"}}
	r, _ := ring.Load("")
	s := New(Options{
		Version: "test",
		Config:  func() (*config.Config, error) { return cfg, nil },
		Ring:    r,
		Recognize: func(ctx context.Context, e asr.Engine, words []string) (Recognizer, error) {
			f.hotwords = words
			return fake, nil
		},
		Decide: func(ctx context.Context, c *config.Config, transcript string, apps []protocol.App) dispatch.Result {
			return dispatch.Rules(transcript, apps)
		},
		Log: log.New(os.Stderr, "", 0),
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go s.Serve(ctx, ln)
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	f.client = client{conn: conn, r: bufio.NewReader(conn), t: t}
	return f
}

func TestSession(t *testing.T) {
	f := setupFixture(t, []string{"switch", "Switch to Safari."})
	c, fake := f.client, f.fake
	c.send(protocol.Message{Type: protocol.Hello, Platform: "test"})
	hello := c.expect(protocol.Hello)
	if hello.Version != "test" || !hello.Ready["voice"] || hello.Ready["jev"] {
		t.Fatalf("hello %+v", hello)
	}
	apps := []protocol.App{
		{ID: "finder", Name: "Finder", Running: true, Active: true},
		{ID: "safari", Name: "Safari", Running: true},
	}
	c.send(protocol.Message{Type: protocol.Apps, Apps: apps})
	if ring := c.expect(protocol.Ring); len(ring.Ring) != 2 || ring.Ring[0] != "finder" {
		t.Fatalf("ring %v", ring.Ring)
	}
	c.send(protocol.Message{Type: protocol.Switched, App: "safari"})
	if ring := c.expect(protocol.Ring); ring.Ring[0] != "safari" {
		t.Fatalf("learned ring %v", ring.Ring)
	}

	c.send(protocol.Message{Type: protocol.Start})
	if st := c.expect(protocol.State); st.Phase != protocol.PhaseListening {
		t.Fatalf("state %v", st)
	}
	c.send(protocol.Message{Type: protocol.Audio, PCM: base64.StdEncoding.EncodeToString(make([]byte, 6400))})
	c.send(protocol.Message{Type: protocol.Stop})
	if h := c.expect(protocol.Heard); h.Text != "switch" || h.Final {
		t.Fatalf("heard %+v", h)
	}
	if h := c.expect(protocol.Heard); h.Text != "Switch to Safari." || !h.Final {
		t.Fatalf("final %+v", h)
	}
	result := c.expect(protocol.Result)
	if result.Intent != "command" || result.Action != "switch_app" || result.App != "safari" || result.Source != "rules" {
		t.Fatalf("result %+v", result)
	}
	if st := c.expect(protocol.State); st.Phase != protocol.PhaseIdle {
		t.Fatalf("state %v", st)
	}
	time.Sleep(50 * time.Millisecond)
	if fake.got != 6400 {
		t.Fatalf("audio got %d", fake.got)
	}
	if !strings.Contains(strings.Join(f.hotwords, ","), "Safari") {
		t.Fatalf("hotwords %v", f.hotwords)
	}
}

func TestStartWithoutEngine(t *testing.T) {
	c, _ := setup(t, nil)
	cfg := config.Default()
	r, _ := ring.Load("")
	s := New(Options{Config: func() (*config.Config, error) { return cfg, nil }, Ring: r})
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.Serve(ctx, ln)
	conn, _ := net.Dial("tcp", ln.Addr().String())
	defer conn.Close()
	c = client{conn: conn, r: bufio.NewReader(conn), t: t}
	c.send(protocol.Message{Type: protocol.Start})
	m := c.next()
	if m.Type != protocol.Error || !strings.Contains(m.Message, "not set up") {
		t.Fatalf("%+v", m)
	}
}

func TestCancel(t *testing.T) {
	c, fake := setup(t, []string{"never"})
	c.send(protocol.Message{Type: protocol.Start})
	c.expect(protocol.State)
	c.send(protocol.Message{Type: protocol.Cancel})
	if st := c.expect(protocol.State); st.Phase != protocol.PhaseIdle {
		t.Fatalf("state %v", st)
	}
	if !fake.closed {
		t.Fatal("recognizer not closed")
	}
	// No result follows a cancel.
	c.conn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if line, err := c.r.ReadBytes('\n'); err == nil {
		t.Fatalf("after cancel: %s", line)
	}
}
