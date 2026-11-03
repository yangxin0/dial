# Dial

A virtual [Surface Dial](https://en.wikipedia.org/wiki/Surface_Dial) for macOS and Windows: a small floating dial on your screen that **listens when you click it**, runs what you said as a command or **types it** into the app in front, and turns an **app ring** with the arrow keys.

```
   ┌─────────────────────────┐
   │   ○ Safari   ○ Slack    │   ← → turn the ring: switch apps
   │ ○ Finder   ●   ○ Code   │   ↑ ↓ scroll the app in front
   │   ○ Xcode    ○ Mail     │   click the centre: listen
   │  "switch to safari"     │   say a command, or anything to type
   └─────────────────────────┘
```

Say **“switch to Safari”**, **“open Slack”**, **“scroll down”**, **“go to the top”**, **“close the window”** (English or Chinese: 切换到 Safari、打开 Slack、向下滚动、回到顶部、关闭窗口). Anything that isn't a command is typed where your cursor is.

The ring is **learned**: the apps you pick most, through the dial or by voice, sit first; a pick counts one and counts halve every two weeks, so an app you stopped using drifts off.

## How it works

```
dial/
  core/        Go, shared: 豆包 streaming ASR, Jev (TypeSafe System One), the decision, the learned ring, config
  cmd/         dial-core (the local server the dials talk to) · dial-cli (try the pieces from a terminal)
  settings/    Go + Wails v3: Dial Settings, one window of plain HTML pages
  macos/       Swift/AppKit: the dial window, the microphone, the keys, app switching, scrolling, typing
  windows/     C++/Win32: the same, as a layered window with a keyboard hook, WASAPI, SendInput
```

The native dial owns the screen, the microphone and the keyboard. It starts **dial-core** (bundled next to it) and talks to it over TCP on the loopback interface, one JSON object per line (`core/protocol`). The core streams the audio to **豆包流式语音识别** (Volcengine), takes the final text, and asks **Jev** three questions in one request: *command or dictation?*, *which action?*, *which app, out of the ones that are open?* The answers come back as probabilities; a command above the threshold runs, anything else is typed. Without a Jev key, a small grammar in English and Chinese decides instead, and it also steps in when Jev doesn't answer.

Nothing but the audio and the transcript leaves your computer: the audio goes to Volcengine, the transcript and the names of your open apps go to TypeSafe.

## Build

You need Go 1.25+ (the Makefile fetches the toolchain `go.mod` names with `GOTOOLCHAIN=auto`), and on macOS Xcode or its command-line tools. The Settings app links WebKit through cgo.

```sh
make test        # the Go core and the Swift unit tests
make macos       # dist/Dial.app, with dial-core inside
make settings    # dist/Dial Settings.app
make install     # both into /Applications
make run         # build and open the dial
```

Dial.app is signed ad hoc unless you run `make signing-identity` once: that adds a self-signed "Dial Local Signing" certificate to your login keychain. macOS ties the Accessibility and Microphone grants to the signature, and an ad-hoc signature changes with every rebuild, so the grants have to be given again each time without it.

For Windows, from a Mac or Linux with `mingw-w64` installed (`brew install mingw-w64`):

```sh
make windows     # dist/windows/dial.exe, dial-core.exe, dial-cli.exe, dial-settings.exe
```

On Windows itself, build the dial with CMake and Visual Studio or MinGW (`windows/CMakeLists.txt`) and the Go binaries with `go build ./cmd/... ./settings`. Put them in one folder: `dial.exe` starts `dial-core.exe` from its own folder and opens `dial-settings.exe` from the menu.

> The Windows dial compiles cleanly with mingw-w64 but has not yet run on a Windows machine; the macOS dial is the one that has been exercised. Reports welcome.

## Tests

`make test` runs the Go and Swift unit tests, and CI runs them on every push. On Windows CI also starts the real dial and checks that it connects to dial-core, stays up, and takes the core down with it.

`make test-scroll` runs on your Mac, because it needs a screen and Accessibility. It builds and starts the dial, then drags the real ring both ways over a native window, a WebKit page, a separate Chrome with a temporary profile, a full-screen terminal program and terminal scrollback. It fails if an app doesn't scroll the right way by about the right amount, if the pointer leaves the ring's path, if a wheel event passes through the system, or if the app loses the front. It also clicks every icon on your ring: each app must come to the front showing a window, whether its windows were closed, hidden or minimized, a click between icons must do nothing, and a press that moves must not switch apps. The icons must hide during a ring drag and come back where they were, and every ring style must show the ring moving. So an app on your ring with no window opens one, and these clicks count as picks in the learned ring, as yours do. It also checks that it's measuring something: an exit of 2 means the run was invalid, for instance because the wrong app was in front or the button wasn't held. It takes over the pointer for a couple of minutes, so don't touch the mouse. `make test-scroll ARGS='--only clicks,icons,styles,native'` runs part of it.

## Set up

Open **Dial Settings**. **Get started** walks you through it, one step at a time, and ticks each step as it's done:

1. **Open the dial.** It sits at the bottom right; drag it anywhere.
2. **Allow Accessibility and the Microphone** (macOS). macOS asks for both when Dial opens: the keys, scrolling and typing need Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility).
3. **Add your speech key**: your Volcengine key, from the [new console](https://console.volcengine.com/speech/new/). The **Voice** page also takes the old console's App ID and Access Token.
4. **Add Jev**, if you like: a [TypeSafe](https://console.typesafe.ai/keys) API key. This is optional, because plain rules decide without it. On the **Commands** page, **Try a sentence** shows what the dial would do with what you type.

If Accessibility shows as allowed in System Settings but Dial still says it isn't: the entry belongs to an earlier build. Without the local signing identity every rebuild is a new app to macOS, so remove Dial from the list with − and add `dist/Dial.app` again with +, and run `make signing-identity` once so it doesn't recur. Settings' checklist shows what Dial itself reports, so it tells you when the grant has taken.

The config is `~/.config/dial/config.json` (`%AppData%\dial\config.json` on Windows), readable by you only; the learned ring is `ring.json` beside it. dial-core reads the config afresh for every recording, so a change in Settings applies at once.

## Use

| Do | Result |
|---|---|
| Click the centre | Start listening; click again, or pause, to stop |
| Hover the dial, then **← →** | Turn the ring: bring the previous or next app to the front |
| Hover, **↑ ↓** | Scroll the app in front |
| Hover, **Space** / **Esc** | Listen / cancel |
| Wheel over the dial | Vertical scrolls the app in front; horizontal turns the ring |
| Click an app's icon on the ring | Bring it to the front, opening a window if it has none; a click between icons does nothing |
| Drag around the ring | Scrolls the app in front like the wheel, clockwise down; the icons hide until you let go, and the ring style you chose in Settings ▸ Theme shows it turning |
| Drag the centre | Move the dial |
| Dial Settings, Theme | Change its size and transparency, live |
| Right-click (Windows) or the menu-bar icon (macOS) | Listen, Settings, Quit |

The keys are the dial's only while the pointer is over it, so they stay your apps' keys otherwise.

What you can say, in English or Chinese, is in `core/dispatch`: switch to / open an app, scroll up / down, top / bottom, close the window. Everything else is dictation and gets typed as heard.

## From a terminal

```sh
.build/dial-cli test                                   # the speech engine and Jev credentials
.build/dial-cli decide "切换到 Slack" --apps Finder,Safari,Slack
.build/dial-cli asr recording.pcm                      # 16 kHz 16-bit mono PCM
.build/dial-cli ring                                   # the learned ring
```

## Protocol

Dial → core: `hello`, `apps` (the app list, whenever it changes), `start`, `audio` (base64 PCM, 200 ms a packet), `stop`, `cancel`, `switched` (the user turned the ring to an app). Core → dial: `hello` (what is set up), `ring` (ids in order), `state` (idle / listening / thinking), `heard` (text so far), `result` (intent, action, app, or text to type), `error`. See `core/protocol/protocol.go`.

## Credits

The 豆包 streaming client and the microphone capture come from [Fluent](https://github.com/yangxin0/fluent); the Settings app is built the way [magpie](https://github.com/yetone/magpie) builds its own.
