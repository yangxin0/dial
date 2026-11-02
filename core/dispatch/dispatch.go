// Package dispatch turns what was heard into what the dial does: a
// command (switch to or open an app, scroll, close the window) or text to
// type. Jev decides when it is set up; a few plain rules decide otherwise,
// and stand in when Jev is unreachable.
package dispatch

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"github.com/yangxin0/dial/core/jev"
	"github.com/yangxin0/dial/core/protocol"
)

// Action is what a command does.
type Action string

const (
	None        Action = "none"
	SwitchApp   Action = "switch_app"
	OpenApp     Action = "open_app"
	ScrollUp    Action = "scroll_up"
	ScrollDown  Action = "scroll_down"
	PageTop     Action = "page_top"
	PageBottom  Action = "page_bottom"
	CloseWindow Action = "close_window"
)

// Intents.
const (
	Command   = "command"
	Dictation = "dictation"
)

const (
	DefaultCommandThreshold = 0.6
	DefaultAppThreshold     = 0.5
	// MaxApps Jev is asked to choose among.
	MaxApps = 60
)

// Result is the decision.
type Result struct {
	Transcript string
	Intent     string
	Action     Action
	// App is the id of the app to switch to or open, AppName its name.
	App, AppName string
	// Confidence is Jev's in the intent, or 1 for a rule.
	Confidence float64
	// Text to type, for dictation.
	Text string
	// Source: "jev" or "rules".
	Source string
	// Note says why a command came out as none.
	Note string
}

// Message is the Result as the dial gets it.
func (r Result) Message() protocol.Message {
	return protocol.Message{Type: protocol.Result, Transcript: r.Transcript, Intent: r.Intent, Action: string(r.Action),
		App: r.App, AppName: r.AppName, Confidence: r.Confidence, Text: r.Text, Source: r.Source, Message: r.Note}
}

// Decider decides with Jev when it is set up, with rules otherwise.
type Decider struct {
	Jev              jev.Client
	CommandThreshold float64
	AppThreshold     float64
}

// Decide is the decision for a transcript, given the apps there are.
func (d Decider) Decide(ctx context.Context, transcript string, apps []protocol.App) Result {
	text := strings.TrimSpace(transcript)
	if text == "" {
		return Result{Intent: Dictation, Action: None, Source: "rules"}
	}
	if d.Jev.Configured() {
		if r, err := d.decideWithJev(ctx, text, apps); err == nil {
			return r
		} else {
			r := Rules(text, apps)
			r.Note = strings.TrimSpace(r.Note + " jev failed: " + err.Error())
			return r
		}
	}
	return Rules(text, apps)
}

// Questions are what Jev is asked about a transcript: the intent, the
// action should it be a command, and the app should the action need one,
// all at once. keys maps the app options back to apps.
func Questions(apps []protocol.App) (questions map[string]jev.Question, keys map[string]protocol.App) {
	questions = map[string]jev.Question{
		"intent": jev.Choice("Is the user giving the computer a command, or dictating text to be typed as it is into the app in front?", map[string]string{
			Command:   "A command to the computer: switch to or open an app, scroll the page, go to the top or bottom, close the window. Usually short and imperative, in English or Chinese.",
			Dictation: "Words meant to be typed as text: a sentence, a message, a note, anything that is not an instruction to the computer itself.",
		}),
		"action": jev.Choice("Supposing the transcript is a command to the computer, which action is it?", map[string]string{
			string(SwitchApp):   "Switch to, go to, or bring up an app that is already open (切换到, 打开 an app that is running).",
			string(OpenApp):     "Open, launch or start an app (打开, 启动, 运行).",
			string(ScrollUp):    "Scroll up, page up, go back up (向上滚动, 往上).",
			string(ScrollDown):  "Scroll down, page down, keep going (向下滚动, 往下).",
			string(PageTop):     "Go to the top of the page or document (回到顶部, 最上面).",
			string(PageBottom):  "Go to the bottom or end of the page (到底部, 最下面).",
			string(CloseWindow): "Close the window or tab (关闭窗口, 关闭标签).",
			string(None):        "None of these actions, or not a command at all.",
		}),
	}
	keys = map[string]protocol.App{}
	options := map[string]string{"none": "No app is named, or the app named is not in this list."}
	for i, a := range apps {
		if i >= MaxApps || a.Name == "" {
			continue
		}
		key := fmt.Sprintf("app_%d", i+1)
		keys[key] = a
		state := "not running"
		if a.Running {
			state = "running"
		}
		options[key] = fmt.Sprintf("The app named %q (%s).", a.Name, state)
	}
	questions["app"] = jev.Choice("Supposing the transcript asks to switch to or open an app, which app in `apps` does it name? Names may be spoken loosely, in part, or in another language.", options)
	return questions, keys
}

func (d Decider) decideWithJev(ctx context.Context, text string, apps []protocol.App) (Result, error) {
	questions, keys := Questions(apps)
	names := make([]string, 0, len(keys))
	for _, a := range keys {
		names = append(names, a.Name)
	}
	sort.Strings(names)
	state := map[string]any{
		"transcript": text,
		"apps":       names,
		"note":       "The transcript is speech recognized from a microphone, so words may be misheard; punctuation was added by the recognizer.",
	}
	resp, err := d.Jev.Ask(ctx, state, questions)
	if err != nil {
		return Result{}, err
	}
	commandThreshold, appThreshold := d.CommandThreshold, d.AppThreshold
	if commandThreshold <= 0 {
		commandThreshold = DefaultCommandThreshold
	}
	if appThreshold <= 0 {
		appThreshold = DefaultAppThreshold
	}
	intent := resp.Answers["intent"]
	r := Result{Transcript: text, Source: "jev", Confidence: intent.P(Command)}
	if intent.Choice != Command || intent.P(Command) < commandThreshold {
		r.Intent, r.Action, r.Text = Dictation, None, text
		return r, nil
	}
	r.Intent = Command
	r.Action = Action(resp.Answers["action"].Choice)
	switch r.Action {
	case SwitchApp, OpenApp:
		app := resp.Answers["app"]
		if a, ok := keys[app.Choice]; ok && app.P(app.Choice) >= appThreshold {
			r.App, r.AppName = a.ID, a.Name
		} else if a, ok := matchApp(text, apps); ok {
			r.App, r.AppName = a.ID, a.Name
		} else {
			r.Action, r.Note = None, "Which app? None of the open apps was named."
		}
		if r.Action == SwitchApp && r.App != "" && !isRunning(r.App, apps) {
			r.Action = OpenApp
		}
	case ScrollUp, ScrollDown, PageTop, PageBottom, CloseWindow:
	default:
		r.Action, r.Note = None, "That sounded like a command, but not one the dial knows."
	}
	return r, nil
}

func isRunning(id string, apps []protocol.App) bool {
	for _, a := range apps {
		if a.ID == id {
			return a.Running
		}
	}
	return false
}

// The rules: a small grammar in English and Chinese, for when Jev is not
// set up or does not answer.
var (
	trailing = regexp.MustCompile(`[\s\p{P}]+$`)
	leading  = regexp.MustCompile(`^(please|hey|ok|okay|请|帮我)\s*`)
	switchRe = regexp.MustCompile(`^(?:switch|go|change|jump|move)(?: back)? (?:to|into) (?:the )?(.+)$`)
	openRe   = regexp.MustCompile(`^(?:open|launch|start|run) (?:the )?(.+?)(?: app)?$`)
	switchZh = regexp.MustCompile(`^(?:切换到|切到|跳到|回到|转到)(.+)$`)
	openZh   = regexp.MustCompile(`^(?:打开|启动|运行)(.+)$`)
	scrollUp = regexp.MustCompile(`^(?:scroll|page|go) ?(?:back )?up(?:wards)?$|^(?:向上|往上)(?:滚动|滚|翻|翻页)?$|^上翻$`)
	scrollDn = regexp.MustCompile(`^(?:scroll|page|go) ?(?:on )?down(?:wards)?$|^(?:向下|往下)(?:滚动|滚|翻|翻页)?$|^下翻$`)
	pageTop  = regexp.MustCompile(`^(?:(?:scroll |go |jump )?(?:back )?to (?:the )?)?top(?: of (?:the )?page)?$|^(?:回到|到|回|跳到)?(?:顶部|最上面|最上方|页首)$`)
	pageBot  = regexp.MustCompile(`^(?:(?:scroll |go |jump )?to (?:the )?)?(?:bottom|end)(?: of (?:the )?page)?$|^(?:到|跳到)?(?:底部|最下面|最下方|页尾|末尾)$`)
	closeWin = regexp.MustCompile(`^close(?: (?:this|the))?(?: window| tab)?$|^关闭?(?:窗口|标签|标签页|页面|这个窗口)?$|^关掉(?:窗口|标签|它)?$`)
)

// Rules decides without Jev: a command the grammar knows, else dictation.
func Rules(transcript string, apps []protocol.App) Result {
	text := strings.TrimSpace(transcript)
	r := Result{Transcript: text, Source: "rules", Confidence: 1}
	norm := normalize(text)
	switch {
	case scrollUp.MatchString(norm):
		r.Intent, r.Action = Command, ScrollUp
	case scrollDn.MatchString(norm):
		r.Intent, r.Action = Command, ScrollDown
	case pageTop.MatchString(norm):
		r.Intent, r.Action = Command, PageTop
	case pageBot.MatchString(norm):
		r.Intent, r.Action = Command, PageBottom
	case closeWin.MatchString(norm):
		r.Intent, r.Action = Command, CloseWindow
	default:
		var name string
		var action Action
		if m := switchRe.FindStringSubmatch(norm); m != nil {
			name, action = m[1], SwitchApp
		} else if m := switchZh.FindStringSubmatch(norm); m != nil {
			name, action = m[1], SwitchApp
		} else if m := openRe.FindStringSubmatch(norm); m != nil {
			name, action = m[1], OpenApp
		} else if m := openZh.FindStringSubmatch(norm); m != nil {
			name, action = m[1], OpenApp
		}
		if action == "" {
			r.Intent, r.Action, r.Text = Dictation, None, text
			return r
		}
		r.Intent, r.Action = Command, action
		a, ok := matchApp(name, apps)
		if !ok {
			r.Action, r.Note = None, fmt.Sprintf("No open app is called %q.", strings.TrimSpace(name))
			return r
		}
		r.App, r.AppName = a.ID, a.Name
		if action == SwitchApp && !a.Running {
			r.Action = OpenApp
		}
	}
	return r
}

// normalize lowers the case and drops the recognizer's punctuation.
func normalize(text string) string {
	text = strings.ToLower(strings.TrimSpace(text))
	text = trailing.ReplaceAllString(text, "")
	text = leading.ReplaceAllString(text, "")
	return strings.TrimSpace(text)
}

// matchApp finds the app a phrase names: by the whole name, a word of it,
// or the phrase within the name, the longest name winning.
func matchApp(phrase string, apps []protocol.App) (protocol.App, bool) {
	phrase = strings.ToLower(strings.TrimSpace(trailing.ReplaceAllString(strings.ToLower(phrase), "")))
	if phrase == "" {
		return protocol.App{}, false
	}
	squash := func(s string) string {
		return strings.Map(func(r rune) rune {
			if unicode.IsLetter(r) || unicode.IsNumber(r) {
				return unicode.ToLower(r)
			}
			return -1
		}, s)
	}
	p := squash(phrase)
	var best protocol.App
	bestScore := 0
	for _, a := range apps {
		name := strings.ToLower(a.Name)
		n := squash(name)
		if n == "" {
			continue
		}
		score := 0
		switch {
		case n == p:
			score = 1000 + len(n)
		case strings.Contains(p, n):
			score = 500 + len(n)
		case strings.Contains(n, p) && len(p) >= 3:
			score = 100 + len(p)
		default:
			for _, w := range strings.Fields(name) {
				if w == phrase && len(w) >= 3 {
					score = 50 + len(w)
				}
			}
		}
		if score > bestScore || (score == bestScore && score > 0 && a.Running && !best.Running) {
			best, bestScore = a, score
		}
	}
	return best, bestScore > 0
}
