// Package asr streams speech to 豆包流式语音识别 (Volcengine, ByteDance)
// over its two-way WebSocket endpoint, the framing Fluent uses. Audio is
// 16 kHz, 16-bit, mono PCM; results arrive as text while speaking and a
// final text once the last packet is in.
package asr

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	DefaultResourceID = "volc.seedasr.sauc.duration"
	Endpoint          = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
	// SampleRate and the sample size the endpoint takes.
	SampleRate = 16000
	// ChunkBytes is 200 ms of audio, the packet size the endpoint works
	// best with.
	ChunkBytes = 6400
	// MaxHotwords: the engine takes about 100 tokens of context.
	MaxHotwords = 60
)

// Engine is one speech engine from the config: which service, and its
// credentials. The new console's API key, else the old console's App ID
// and Access Token.
type Engine struct {
	Name        string `json:"name"`
	Kind        string `json:"type"`
	APIKey      string `json:"apiKey"`
	AppID       string `json:"appId"`
	AccessToken string `json:"accessToken"`
	ResourceID  string `json:"resourceId"`
}

// Normalized trims every field and fills the defaults in.
func (e Engine) Normalized() Engine {
	e.Name = strings.TrimSpace(e.Name)
	e.Kind = strings.ToLower(strings.TrimSpace(e.Kind))
	e.APIKey = strings.TrimSpace(e.APIKey)
	e.AppID = strings.TrimSpace(e.AppID)
	e.AccessToken = strings.TrimSpace(e.AccessToken)
	e.ResourceID = strings.TrimSpace(e.ResourceID)
	if e.Kind == "" {
		e.Kind = "volcengine"
	}
	if e.ResourceID == "" {
		e.ResourceID = DefaultResourceID
	}
	return e
}

// Configured: a known service with credentials.
func (e Engine) Configured() bool {
	e = e.Normalized()
	return e.Kind == "volcengine" && (e.APIKey != "" || (e.AppID != "" && e.AccessToken != ""))
}

// Headers are the handshake's: credentials, the resource, a fresh id.
func (e Engine) Headers(connectID string) http.Header {
	e = e.Normalized()
	h := http.Header{}
	h.Set("X-Api-Resource-Id", e.ResourceID)
	h.Set("X-Api-Connect-Id", connectID)
	h.Set("X-Api-Request-Id", connectID)
	if e.APIKey != "" {
		h.Set("X-Api-Key", e.APIKey)
	} else {
		h.Set("X-Api-App-Key", e.AppID)
		h.Set("X-Api-Access-Key", e.AccessToken)
	}
	return h
}

// The binary frames: a 4-byte header (version and size, type and flags,
// serialization and compression, reserved), big-endian sizes, then the
// payload. Requests go uncompressed.

func frame(header [4]byte, payload []byte) []byte {
	b := append(header[:], 0, 0, 0, 0)
	binary.BigEndian.PutUint32(b[4:], uint32(len(payload)))
	return append(b, payload...)
}

// ClientRequestFrame is the first message: the request parameters as JSON.
func ClientRequestFrame(payload []byte) []byte {
	return frame([4]byte{0x11, 0x10, 0x10, 0x00}, payload)
}

// AudioFrame is one packet of PCM; the last one asks for the final text.
func AudioFrame(pcm []byte, last bool) []byte {
	flags := byte(0x20)
	if last {
		flags = 0x22
	}
	return frame([4]byte{0x11, flags, 0x00, 0x00}, pcm)
}

// ServerMessage is a reply: a result (Last once final) or an error.
type ServerMessage struct {
	Last      bool
	Payload   []byte
	IsError   bool
	ErrorCode uint32
	ErrorText string
}

var ErrTruncated = errors.New("truncated frame")

// ParseServerFrame reads one reply.
func ParseServerFrame(b []byte) (ServerMessage, error) {
	if len(b) < 4 {
		return ServerMessage{}, ErrTruncated
	}
	at := int(b[0]&0x0F) * 4
	kind, flags, compression := b[1]>>4, b[1]&0x0F, b[2]&0x0F
	word := func() (uint32, error) {
		if at+4 > len(b) {
			return 0, ErrTruncated
		}
		at += 4
		return binary.BigEndian.Uint32(b[at-4 : at]), nil
	}
	switch kind {
	case 0b1001:
		if flags&0b0001 != 0 {
			if _, err := word(); err != nil { // the sequence number
				return ServerMessage{}, err
			}
		}
		size, err := word()
		if err != nil || at+int(size) > len(b) {
			return ServerMessage{}, ErrTruncated
		}
		payload := b[at : at+int(size)]
		if compression == 1 {
			r, err := gzip.NewReader(bytes.NewReader(payload))
			if err != nil {
				return ServerMessage{}, err
			}
			if payload, err = io.ReadAll(r); err != nil {
				return ServerMessage{}, err
			}
		}
		return ServerMessage{Last: flags&0b0010 != 0, Payload: payload}, nil
	case 0b1111:
		code, err := word()
		if err != nil {
			return ServerMessage{}, err
		}
		size, err := word()
		if err != nil || at+int(size) > len(b) {
			return ServerMessage{}, ErrTruncated
		}
		return ServerMessage{IsError: true, ErrorCode: code, ErrorText: string(b[at : at+int(size)])}, nil
	}
	return ServerMessage{}, fmt.Errorf("unknown message type %d", kind)
}

// TextOf is the text of a result payload: `result.text`, or the first
// result's when `result` is a list.
func TextOf(payload []byte) (string, bool) {
	var object struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(payload, &object) != nil || len(object.Result) == 0 {
		return "", false
	}
	var one struct {
		Text *string `json:"text"`
	}
	if json.Unmarshal(object.Result, &one) == nil && one.Text != nil {
		return *one.Text, true
	}
	var many []struct {
		Text *string `json:"text"`
	}
	if json.Unmarshal(object.Result, &many) == nil && len(many) > 0 && many[0].Text != nil {
		return *many[0].Text, true
	}
	return "", false
}

// RequestJSON is the parameters of a recognition: PCM as the dial records
// it, the two-pass mode (fast text while speaking, a more accurate pass per
// sentence), punctuation and written-out numbers, and hotwords to favor.
func RequestJSON(uid string, hotwords []string) []byte {
	request := map[string]any{
		"model_name":       "bigmodel",
		"enable_nonstream": true,
		"enable_itn":       true,
		"enable_punc":      true,
		"result_type":      "full",
	}
	if len(hotwords) > MaxHotwords {
		hotwords = hotwords[:MaxHotwords]
	}
	if len(hotwords) > 0 {
		words := make([]map[string]string, 0, len(hotwords))
		for _, w := range hotwords {
			words = append(words, map[string]string{"word": w})
		}
		context, _ := json.Marshal(map[string]any{"hotwords": words})
		request["corpus"] = map[string]any{"context": string(context)}
	}
	b, _ := json.Marshal(map[string]any{
		"user":    map[string]any{"uid": uid},
		"audio":   map[string]any{"format": "pcm", "codec": "raw", "rate": SampleRate, "bits": 16, "channel": 1},
		"request": request,
	})
	return b
}

// NewID is a fresh connect id.
func NewID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// EmptyAudio is the service's code for audio with no speech in it: the
// credentials were taken.
const EmptyAudio = 45000002

// Event is what a recognition reports: text so far, the final text, or
// why it failed. The channel closes after a final text or an error.
type Event struct {
	Text  string
	Final bool
	Err   error
}

// Recognizer is one recognition over the endpoint: Start it, Send audio as
// it comes, Finish for the final text.
type Recognizer struct {
	conn   *websocket.Conn
	ctx    context.Context
	cancel context.CancelFunc
	events chan Event
	mu     sync.Mutex
	done   bool
	// LogID is the server's log id, for reports.
	LogID string
}

// Dialer connects; it is replaceable for tests.
var Dialer = func(ctx context.Context, url string, headers http.Header) (*websocket.Conn, *http.Response, error) {
	return websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: headers})
}

// Start connects and sends the request; events follow on Events.
func Start(ctx context.Context, e Engine, hotwords []string) (*Recognizer, error) {
	if !e.Configured() {
		return nil, errors.New("the speech engine is not set up")
	}
	ctx, cancel := context.WithCancel(ctx)
	dialCtx, dialCancel := context.WithTimeout(ctx, 15*time.Second)
	defer dialCancel()
	conn, resp, err := Dialer(dialCtx, Endpoint, e.Headers(NewID()))
	logID := ""
	if resp != nil {
		logID = resp.Header.Get("X-Tt-Logid")
	}
	if err != nil {
		cancel()
		if resp != nil && resp.StatusCode != http.StatusSwitchingProtocols {
			reason := ""
			if resp.StatusCode == 401 || resp.StatusCode == 403 {
				reason = ": the engine refused the key"
			}
			return nil, fmt.Errorf("HTTP %d%s (logid %s)", resp.StatusCode, reason, logID)
		}
		return nil, err
	}
	conn.SetReadLimit(1 << 20)
	r := &Recognizer{conn: conn, ctx: ctx, cancel: cancel, events: make(chan Event, 16), LogID: logID}
	if err := r.write(ClientRequestFrame(RequestJSON("dial", hotwords))); err != nil {
		r.Close()
		return nil, err
	}
	go r.read()
	return r, nil
}

// Events is the recognition's text as it comes.
func (r *Recognizer) Events() <-chan Event { return r.events }

func (r *Recognizer) write(b []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.done {
		return errors.New("recognition is over")
	}
	ctx, cancel := context.WithTimeout(r.ctx, 10*time.Second)
	defer cancel()
	return r.conn.Write(ctx, websocket.MessageBinary, b)
}

// Send is a packet of audio.
func (r *Recognizer) Send(pcm []byte) error {
	if len(pcm) == 0 {
		return nil
	}
	return r.write(AudioFrame(pcm, false))
}

// Finish sends what is left as the last packet; the final text follows.
func (r *Recognizer) Finish(pcm []byte) error {
	return r.write(AudioFrame(pcm, true))
}

// Close drops the recognition; no more events come.
func (r *Recognizer) Close() {
	r.mu.Lock()
	already := r.done
	r.done = true
	r.mu.Unlock()
	r.cancel()
	if !already {
		r.conn.Close(websocket.StatusGoingAway, "")
	}
}

func (r *Recognizer) read() {
	defer close(r.events)
	last := ""
	for {
		_, data, err := r.conn.Read(r.ctx)
		if err != nil {
			r.mu.Lock()
			done := r.done
			r.mu.Unlock()
			if !done {
				r.fail(fmt.Errorf("the engine hung up: %w", err))
			}
			return
		}
		msg, err := ParseServerFrame(data)
		if err != nil {
			r.fail(fmt.Errorf("unreadable reply: %w", err))
			return
		}
		if msg.IsError {
			if msg.ErrorCode == EmptyAudio {
				r.events <- Event{Text: last, Final: true}
				r.finish()
				return
			}
			r.fail(fmt.Errorf("engine error %d: %s", msg.ErrorCode, msg.ErrorText))
			return
		}
		if text, ok := TextOf(msg.Payload); ok {
			last = text
		}
		r.events <- Event{Text: last, Final: msg.Last}
		if msg.Last {
			r.finish()
			return
		}
	}
}

func (r *Recognizer) finish() {
	r.mu.Lock()
	r.done = true
	r.mu.Unlock()
	r.conn.Close(websocket.StatusNormalClosure, "")
	r.cancel()
}

func (r *Recognizer) fail(err error) {
	if r.LogID != "" {
		err = fmt.Errorf("%w (logid %s)", err, r.LogID)
	}
	r.events <- Event{Err: err}
	r.mu.Lock()
	r.done = true
	r.mu.Unlock()
	r.conn.Close(websocket.StatusAbnormalClosure, "")
	r.cancel()
}

// Test sends one second of silence with the engine's credentials: whether
// the service takes them, and how long the round trip is.
func Test(ctx context.Context, e Engine) (time.Duration, string, error) {
	if !e.Configured() {
		return 0, "", errors.New("the speech engine is not set up")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	started := time.Now()
	r, err := Start(ctx, e, nil)
	if err != nil {
		return 0, "", err
	}
	defer r.Close()
	silence := make([]byte, ChunkBytes)
	for i := 0; i < 5; i++ {
		var err error
		if i == 4 {
			err = r.Finish(silence)
		} else {
			err = r.Send(silence)
		}
		if err != nil {
			return 0, r.LogID, err
		}
	}
	for ev := range r.Events() {
		if ev.Err != nil {
			return 0, r.LogID, ev.Err
		}
		if ev.Final {
			return time.Since(started), r.LogID, nil
		}
	}
	return 0, r.LogID, errors.New("the engine closed without answering")
}
