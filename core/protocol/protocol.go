// Package protocol is what a native dial and dial-core say to each other:
// JSON objects, one per line, over TCP on the loopback interface. The dial
// owns the screen, the microphone and the keyboard; the core owns the
// speech engine, the decision and the learned ring.
package protocol

// DefaultPort is where dial-core listens unless the config says otherwise.
const DefaultPort = 47831

// App is one application the dial can switch to or open.
type App struct {
	// ID is what the platform switches by: a bundle id on macOS, the
	// executable's path on Windows.
	ID   string `json:"id"`
	Name string `json:"name"`
	// Running apps are on the ring; others can only be opened by voice.
	Running bool `json:"running"`
	// Active is the frontmost app.
	Active bool `json:"active,omitempty"`
}

// Message types, dial → core.
const (
	// Hello opens a connection: Platform and Version. The core answers
	// with a Hello of its own, with Ready saying what is set up.
	Hello = "hello"
	// Apps is the current app list, whenever it changes. The core answers
	// with a Ring.
	Apps = "apps"
	// Start begins a recording: the core connects to the speech engine.
	Start = "start"
	// Audio carries 16 kHz 16-bit mono PCM in PCM, base64.
	Audio = "audio"
	// Stop ends the recording; the final text and the Result follow.
	Stop = "stop"
	// Cancel drops the recording with no result.
	Cancel = "cancel"
	// Switched says the user turned the ring to App, so the core learns it.
	// The core answers with a Ring.
	Switched = "switched"
	// Status is the dial's grants (Ready: "accessibility", "microphone"),
	// sent whenever they change; the core passes them on to Settings.
	Status = "status"
)

// DialStatus is what the core knows of the connected dial, in its Hello to
// any client: Settings' checklist reads it.
type DialStatus struct {
	Connected     bool   `json:"connected"`
	Platform      string `json:"platform,omitempty"`
	Accessibility bool   `json:"accessibility"`
	Microphone    bool   `json:"microphone"`
}

// Message types, core → dial.
const (
	// Ring is the ring's app ids in order, most used first.
	Ring = "ring"
	// Heard is the text so far (Text), Final once the engine is done.
	Heard = "heard"
	// Result is what the utterance meant: Intent "command" with an Action
	// and maybe an App, or Intent "dictation" with Text to type.
	Result = "result"
	// State is the core's Phase: idle, listening, thinking.
	State = "state"
	// Error carries a Message for the user; the recording is over.
	Error = "error"
	// Theme says how the dial should look, on connecting and when it changes.
	Theme = "theme"
)

// ThemeValues is how the dial looks.
type ThemeValues struct {
	// Size is 1 for the normal size.
	Size float64 `json:"size"`
	// Transparency is 0 for solid.
	Transparency float64 `json:"transparency"`
}

// Phases of a State message.
const (
	PhaseIdle      = "idle"
	PhaseListening = "listening"
	PhaseThinking  = "thinking"
)

// Message is every message; which fields are set depends on Type.
type Message struct {
	Type string `json:"type"`

	Platform string `json:"platform,omitempty"`
	Version  string `json:"version,omitempty"`
	// Ready, in the core's Hello: "voice" and "jev", whether each is set up.
	// In a dial's Hello or Status: "accessibility" and "microphone".
	Ready map[string]bool `json:"ready,omitempty"`
	// Dial, in the core's Hello: the connected dial and its grants.
	Dial *DialStatus `json:"dial,omitempty"`

	Apps []App    `json:"apps,omitempty"`
	Ring []string `json:"ring,omitempty"`

	PCM string `json:"pcm,omitempty"`

	Text  string `json:"text,omitempty"`
	Final bool   `json:"final,omitempty"`

	Transcript string  `json:"transcript,omitempty"`
	Intent     string  `json:"intent,omitempty"`
	Action     string  `json:"action,omitempty"`
	App        string  `json:"app,omitempty"`
	AppName    string  `json:"appName,omitempty"`
	Confidence float64 `json:"confidence,omitempty"`
	// Source is what decided: "jev" or "rules".
	Source string `json:"source,omitempty"`

	Theme *ThemeValues `json:"theme,omitempty"`

	Phase   string `json:"phase,omitempty"`
	Message string `json:"message,omitempty"`
}
