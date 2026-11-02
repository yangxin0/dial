package asr

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"testing"
)

func serverFrame(flags byte, compression byte, payload []byte) []byte {
	b := []byte{0x11, 0x90 | flags, compression, 0x00}
	if flags&0b0001 != 0 {
		b = binary.BigEndian.AppendUint32(b, 1)
	}
	b = binary.BigEndian.AppendUint32(b, uint32(len(payload)))
	return append(b, payload...)
}

func TestFrames(t *testing.T) {
	req := ClientRequestFrame([]byte(`{"a":1}`))
	if !bytes.Equal(req[:4], []byte{0x11, 0x10, 0x10, 0x00}) || binary.BigEndian.Uint32(req[4:8]) != 7 {
		t.Fatalf("request frame %x", req)
	}
	audio := AudioFrame([]byte{1, 2, 3}, false)
	if audio[1] != 0x20 || len(audio) != 11 {
		t.Fatalf("audio frame %x", audio)
	}
	if AudioFrame(nil, true)[1] != 0x22 {
		t.Fatal("last packet flag")
	}
}

func TestParseServerFrame(t *testing.T) {
	msg, err := ParseServerFrame(serverFrame(0b0001, 0, []byte(`{"result":{"text":"hi"}}`)))
	if err != nil || msg.Last || msg.IsError {
		t.Fatalf("partial: %+v %v", msg, err)
	}
	if text, ok := TextOf(msg.Payload); !ok || text != "hi" {
		t.Fatalf("text %q %v", text, ok)
	}
	var zipped bytes.Buffer
	w := gzip.NewWriter(&zipped)
	w.Write([]byte(`{"result":[{"text":"final"}]}`))
	w.Close()
	msg, err = ParseServerFrame(serverFrame(0b0011, 1, zipped.Bytes()))
	if err != nil || !msg.Last {
		t.Fatalf("final: %+v %v", msg, err)
	}
	if text, _ := TextOf(msg.Payload); text != "final" {
		t.Fatalf("text %q", text)
	}
	errFrame := []byte{0x11, 0xF0, 0x00, 0x00}
	errFrame = binary.BigEndian.AppendUint32(errFrame, 45000002)
	errFrame = binary.BigEndian.AppendUint32(errFrame, 5)
	errFrame = append(errFrame, "empty"...)
	msg, err = ParseServerFrame(errFrame)
	if err != nil || !msg.IsError || msg.ErrorCode != EmptyAudio || msg.ErrorText != "empty" {
		t.Fatalf("error: %+v %v", msg, err)
	}
	if _, err := ParseServerFrame([]byte{0x11}); err != ErrTruncated {
		t.Fatalf("truncated: %v", err)
	}
}

func TestEngine(t *testing.T) {
	if (Engine{}).Configured() {
		t.Fatal("empty engine configured")
	}
	e := Engine{Name: " 豆包 ", APIKey: " key "}
	if !e.Configured() {
		t.Fatal("api key engine not configured")
	}
	h := e.Headers("id")
	if h.Get("X-Api-Key") != "key" || h.Get("X-Api-Resource-Id") != DefaultResourceID || h.Get("X-Api-Connect-Id") != "id" {
		t.Fatalf("headers %v", h)
	}
	old := Engine{AppID: "app", AccessToken: "token", Kind: "VolcEngine"}
	if !old.Configured() || old.Headers("x").Get("X-Api-App-Key") != "app" {
		t.Fatal("old console credentials")
	}
	if (Engine{Kind: "other", APIKey: "k"}).Configured() {
		t.Fatal("unknown kind configured")
	}
}

func TestRequestJSON(t *testing.T) {
	b := RequestJSON("dial", []string{"Safari", "Slack"})
	if !bytes.Contains(b, []byte(`"rate":16000`)) || !bytes.Contains(b, []byte(`hotwords`)) || !bytes.Contains(b, []byte(`Safari`)) {
		t.Fatalf("request %s", b)
	}
	if bytes.Contains(RequestJSON("dial", nil), []byte("corpus")) {
		t.Fatal("corpus without hotwords")
	}
}
