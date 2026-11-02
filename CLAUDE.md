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
  a wheel event posted to a process is never delivered to a view, and
  the Accessibility API is not universal (Chrome's page has no scroll
  bar, WezTerm no scroll area). Post the wheel into the system at the
  window's location, then a mouse move back to where the cursor was, in
  the same queue. Measured on 2026-11-02; don't swap it for posting to
  a pid again.
