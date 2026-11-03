// Package server is dial-core's side of the protocol: one session per
// connected dial, which records through the speech engine, decides, and
// keeps the ring learned.
package server

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/yangxin0/dial/core/asr"
	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/dispatch"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
)

// MaxRecording is how long a recording may run before it ends by itself.
const MaxRecording = 60 * time.Second

// Recognizer is one recording's engine; asr.Recognizer, or a fake.
type Recognizer interface {
	Send(pcm []byte) error
	Finish(pcm []byte) error
	Events() <-chan asr.Event
	Close()
}

// Options wire a Server; every one but Ring has a default.
type Options struct {
	Version string
	// Config loads the config, afresh each time.
	Config func() (*config.Config, error)
	Ring   *ring.Ring
	// Recognize starts a recording; asr.Start by default.
	Recognize func(ctx context.Context, e asr.Engine, hotwords []string) (Recognizer, error)
	// Decide decides; the config's Decider by default.
	Decide func(ctx context.Context, c *config.Config, transcript string, apps []protocol.App) dispatch.Result
	Log    *log.Logger
	// ThemePoll is how often the config is checked for a new theme.
	ThemePoll time.Duration
}

// Server accepts dials.
type Server struct {
	o Options

	mu   sync.Mutex
	dial protocol.DialStatus
	// dialSession is the session of the dial itself (not Settings or a
	// check), whose grants dial is.
	dialSession *session
}

// dialStatus is a copy of what the dial reported.
func (s *Server) dialStatus() *protocol.DialStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.dial
	return &d
}

// isDial says whether platform names a native dial, as opposed to
// Settings or a check from a terminal.
func isDial(platform string) bool {
	return platform == "macos" || platform == "windows"
}

func (s *Server) setDial(sess *session, platform string, ready map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess != nil && s.dialSession != sess {
		s.dialSession = sess
		s.dial = protocol.DialStatus{}
	}
	s.dial.Connected = true
	if platform != "" {
		s.dial.Platform = platform
	}
	if v, ok := ready["accessibility"]; ok {
		s.dial.Accessibility = v
	}
	if v, ok := ready["microphone"]; ok {
		s.dial.Microphone = v
	}
}

// noteRing keeps the ring the dial was last sent, so a check can say which
// app sits where.
func (s *Server) noteRing(sess *session, order []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dialSession == sess {
		s.dial.Ring = order
	}
}

func (s *Server) dialGone(sess *session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dialSession == sess {
		s.dialSession = nil
		s.dial.Connected = false
	}
}

// New is a server with the options filled in.
func New(o Options) *Server {
	if o.Config == nil {
		o.Config = func() (*config.Config, error) { return config.Load(config.Path()) }
	}
	if o.Ring == nil {
		o.Ring, _ = ring.Load("")
	}
	if o.Recognize == nil {
		o.Recognize = func(ctx context.Context, e asr.Engine, hotwords []string) (Recognizer, error) {
			return asr.Start(ctx, e, hotwords)
		}
	}
	if o.Decide == nil {
		o.Decide = func(ctx context.Context, c *config.Config, transcript string, apps []protocol.App) dispatch.Result {
			return c.Decider().Decide(ctx, transcript, apps)
		}
	}
	if o.ThemePoll <= 0 {
		o.ThemePoll = 400 * time.Millisecond
	}
	if o.Log == nil {
		o.Log = log.Default()
	}
	return &Server{o: o}
}

// Serve accepts until the listener closes or ctx ends.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.Handle(ctx, conn)
	}
}

// Handle runs one dial's session until it hangs up.
func (s *Server) Handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sess := &session{s: s, conn: conn, ctx: ctx}
	defer sess.cancelRecording()
	defer s.dialGone(sess)
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var m protocol.Message
		if err := json.Unmarshal(line, &m); err != nil {
			sess.send(protocol.Message{Type: protocol.Error, Message: "unreadable message: " + err.Error()})
			continue
		}
		sess.handle(m)
	}
}

// session is one connected dial.
type session struct {
	s    *Server
	conn net.Conn
	ctx  context.Context

	writeMu sync.Mutex

	mu        sync.Mutex
	apps      []protocol.App
	recording *recording

	watchingTheme bool
}

// recording is one in progress.
type recording struct {
	rec    Recognizer
	cancel context.CancelFunc
	done   chan struct{}
	// finished once Stop was sent; the final text is on its way.
	finished bool
	// cancelled once the dial gave up on it: no result follows.
	cancelled bool
	timer     *time.Timer
}

func (s *Server) isDialSession(sess *session) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dialSession == sess
}

func (sess *session) send(m protocol.Message) {
	data, err := json.Marshal(m)
	if err != nil {
		return
	}
	sess.writeMu.Lock()
	defer sess.writeMu.Unlock()
	sess.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	sess.conn.Write(append(data, '\n'))
}

func (sess *session) sendState(phase string) {
	sess.send(protocol.Message{Type: protocol.State, Phase: phase})
}

func (sess *session) fail(message string) {
	sess.send(protocol.Message{Type: protocol.Error, Message: message})
	sess.sendState(protocol.PhaseIdle)
}

func (sess *session) config() *config.Config {
	c, err := sess.s.o.Config()
	if err != nil {
		sess.s.o.Log.Printf("config: %v", err)
	}
	if c == nil {
		c = config.Default()
	}
	return c
}

func (sess *session) sendRing() {
	c := sess.config()
	sess.mu.Lock()
	apps := sess.apps
	sess.mu.Unlock()
	order := sess.s.o.Ring.Order(apps, c.Ring.Size, time.Now())
	if order == nil {
		order = []string{}
	}
	sess.s.noteRing(sess, order)
	sess.send(protocol.Message{Type: protocol.Ring, Ring: order})
}

func (sess *session) handle(m protocol.Message) {
	switch m.Type {
	case protocol.Hello:
		if isDial(m.Platform) {
			sess.s.setDial(sess, m.Platform, m.Ready)
		}
		c := sess.config()
		sess.send(protocol.Message{Type: protocol.Hello, Version: sess.s.o.Version, Ready: c.Ready(), Dial: sess.s.dialStatus()})
		sess.sendState(protocol.PhaseIdle)
		if isDial(m.Platform) && !sess.watchingTheme {
			sess.watchingTheme = true
			go sess.watchTheme(c.Theme)
		}
	case protocol.Status:
		if sess.s.isDialSession(sess) {
			sess.s.setDial(sess, "", m.Ready)
		}
	case protocol.Apps:
		sess.mu.Lock()
		sess.apps = m.Apps
		sess.mu.Unlock()
		sess.sendRing()
	case protocol.Switched:
		name := ""
		sess.mu.Lock()
		for _, a := range sess.apps {
			if a.ID == m.App {
				name = a.Name
			}
		}
		sess.mu.Unlock()
		sess.s.o.Ring.Record(m.App, name, time.Now())
		if err := sess.s.o.Ring.Save(); err != nil {
			sess.s.o.Log.Printf("ring: %v", err)
		}
		sess.sendRing()
	case protocol.Start:
		sess.start()
	case protocol.Audio:
		pcm, err := base64.StdEncoding.DecodeString(m.PCM)
		if err != nil {
			sess.fail("unreadable audio")
			return
		}
		sess.mu.Lock()
		r := sess.recording
		sess.mu.Unlock()
		if r == nil || r.finished {
			return
		}
		if err := r.rec.Send(pcm); err != nil {
			sess.s.o.Log.Printf("send: %v", err)
		}
	case protocol.Stop:
		sess.stop()
	case protocol.Cancel:
		sess.cancelRecording()
		sess.sendState(protocol.PhaseIdle)
	default:
		sess.send(protocol.Message{Type: protocol.Error, Message: "unknown message type " + m.Type})
	}
}

// watchTheme tells the dial how to look now and whenever that changes, so a
// slider in Settings, or an edit to the file, shows at once.
func (sess *session) watchTheme(theme protocol.ThemeValues) {
	send := func() {
		value := theme
		sess.send(protocol.Message{Type: protocol.Theme, Theme: &value})
	}
	send()
	ticker := time.NewTicker(sess.s.o.ThemePoll)
	defer ticker.Stop()
	for {
		select {
		case <-sess.ctx.Done():
			return
		case <-ticker.C:
			c, err := sess.s.o.Config()
			if err != nil || c == nil || c.Theme == theme {
				continue
			}
			theme = c.Theme
			send()
		}
	}
}

func (sess *session) start() {
	sess.cancelRecording()
	c := sess.config()
	engine, ok := c.ActiveEngine()
	if !ok || !engine.Configured() {
		sess.fail("The speech engine is not set up: open Dial Settings and add your 豆包 key.")
		return
	}
	sess.mu.Lock()
	apps := sess.apps
	sess.mu.Unlock()
	hotwords := append([]string{}, c.Voice.Hotwords...)
	for _, a := range apps {
		if a.Running && a.Name != "" {
			hotwords = append(hotwords, a.Name)
		}
	}
	ctx, cancel := context.WithCancel(sess.ctx)
	rec, err := sess.s.o.Recognize(ctx, engine, hotwords)
	if err != nil {
		cancel()
		sess.fail("Can't reach the speech engine: " + err.Error())
		return
	}
	r := &recording{rec: rec, cancel: cancel, done: make(chan struct{})}
	r.timer = time.AfterFunc(MaxRecording, func() { sess.stopRecording(r) })
	sess.mu.Lock()
	sess.recording = r
	sess.mu.Unlock()
	sess.sendState(protocol.PhaseListening)
	go sess.listen(c, apps, r)
}

// listen passes the engine's text on, then decides on the final one.
func (sess *session) listen(c *config.Config, apps []protocol.App, r *recording) {
	defer close(r.done)
	defer r.cancel()
	defer r.timer.Stop()
	last, final := "", false
	for ev := range r.rec.Events() {
		if ev.Err != nil {
			sess.clear(r)
			if !sess.cancelled(r) {
				sess.fail(ev.Err.Error())
			}
			return
		}
		last = ev.Text
		sess.send(protocol.Message{Type: protocol.Heard, Text: ev.Text, Final: ev.Final})
		if ev.Final {
			final = true
			break
		}
	}
	sess.clear(r)
	if sess.ctx.Err() != nil || sess.cancelled(r) {
		return
	}
	if !final {
		sess.fail("The speech engine closed without a final text.")
		return
	}
	sess.sendState(protocol.PhaseThinking)
	ctx, cancel := context.WithTimeout(sess.ctx, 25*time.Second)
	defer cancel()
	result := sess.s.o.Decide(ctx, c, last, apps)
	sess.send(result.Message())
	sess.sendState(protocol.PhaseIdle)
}

func (sess *session) cancelled(r *recording) bool {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return r.cancelled
}

// clear forgets r as the recording, if it still is.
func (sess *session) clear(r *recording) {
	sess.mu.Lock()
	if sess.recording == r {
		sess.recording = nil
	}
	sess.mu.Unlock()
}

func (sess *session) stop() {
	sess.mu.Lock()
	r := sess.recording
	sess.mu.Unlock()
	if r == nil {
		return
	}
	sess.stopRecording(r)
}

func (sess *session) stopRecording(r *recording) {
	sess.mu.Lock()
	if r.finished {
		sess.mu.Unlock()
		return
	}
	r.finished = true
	sess.mu.Unlock()
	if err := r.rec.Finish(nil); err != nil {
		sess.s.o.Log.Printf("finish: %v", err)
	}
}

func (sess *session) cancelRecording() {
	sess.mu.Lock()
	r := sess.recording
	sess.recording = nil
	if r != nil {
		r.cancelled = true
	}
	sess.mu.Unlock()
	if r == nil {
		return
	}
	r.timer.Stop()
	r.rec.Close()
	r.cancel()
	select {
	case <-r.done:
	case <-time.After(2 * time.Second):
	}
}

// Listen opens the loopback port; a second core finds it taken and says so.
func Listen(port int) (net.Listener, error) {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		var opErr *net.OpError
		if errors.As(err, &opErr) {
			return nil, fmt.Errorf("port %d is taken: is another dial-core running? (%v)", port, err)
		}
		return nil, err
	}
	return ln, nil
}
