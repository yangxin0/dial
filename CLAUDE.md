# Dial

A virtual Surface Dial for macOS and Windows. See README.md for what it
is and how it is built; the design was settled in discussion #1.

## Commit messages

Write plain commit messages with no AI attribution: do not append
`Co-Authored-By: Claude ...`, "Generated with Claude Code", or any
similar marker or trailer.

## Development

- `make test` runs `go vet`, the Go tests and the Swift unit tests;
  `make macos settings` builds the two app bundles into `dist/`;
  `make windows` cross-compiles the Windows dial with mingw-w64.
- `make test` also loads the Settings pages in a real browser, against the real
  API: the Go build embeds them without reading them, so a broken script builds
  fine. After changing `settings/assets`, also open the real app: `make run`
  rebuilds both apps.
- `make test-scroll` drags the real ring of a fresh build over real apps,
  and takes over the pointer for about a minute, so CI can't run it. Run it
  before saying a change to the pointer, the ring or scrolling works. Exit 2
  means the run was invalid and proved nothing.
- A test proves nothing until it has failed on broken code. When changing
  `macos/Sources/ScrollTest`, run it against an old broken build (b36839c or
  f1fcf8d, built in a `git worktree`, which must fail) and with
  `SCROLLTEST_SABOTAGE=front`, `button` and `old`, which must exit 2, 2 and 1.
  The first version sent absolute positions and passed b36839c, because each
  event put the pointer back on the path. A hand moves relative to the pointer.
- The ring's maths and the wheel event live in `macos/Sources/DialKit`, with no
  UI, so they can be tested. Keep logic there, not in the views.
- The native dials (`macos/`, `windows/`) and `dial-core` meet only in
  `core/protocol/protocol.go`: a change to a message changes both sides.
- `core/` must stay free of platform UI code so it builds for both
  platforms and stays unit-testable.
- Scrolling the app in front on macOS (`macos/Sources/Dial/Input.swift`):
  post the wheel to the app's process with the window number in field 51
  and a window-local position from the private `CGEventSetWindowLocation`.
  Both are undocumented, so a macOS update could break them. Tested on
  2026-11-02 with the button held, as in a ring drag: a native window and
  Chrome scrolled and the pointer stayed put. Without those two values
  (fields 91 and 92 don't help) the event is dropped. Don't post the wheel
  into the system: it moves the real pointer to the event's location, and
  `make test-scroll` fails if one passes through there during a drag. The
  recipe comes from [Orca](https://github.com/stablyai/orca/pull/36005) and
  [2ndscreen](https://github.com/szrunworld/2ndscreen/pull/4).
