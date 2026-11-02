# Dial

A virtual Surface Dial for macOS and Windows. See README.md for what it
is and how it is built; the design was settled in discussion #1.

## Commit messages

Write plain commit messages with no AI attribution: do not append
`Co-Authored-By: Claude ...`, "Generated with Claude Code", or any
similar marker or trailer.

## Development

- `make test` runs `go vet` and the Go tests; `make macos settings`
  builds the two app bundles into `dist/`; `make windows` cross-compiles
  the Windows dial with mingw-w64.
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
  into the system: it moves the real pointer to the event's location. The
  recipe comes from [Orca](https://github.com/stablyai/orca/pull/36005) and
  [2ndscreen](https://github.com/szrunworld/2ndscreen/pull/4).
