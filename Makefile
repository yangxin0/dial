# Dial: the Go core and CLI, the macOS dial (Swift) with the core bundled
# inside, Dial Settings (Go + Wails), and, cross-compiled with mingw-w64,
# the Windows dial (C++) with the Go binaries for Windows.
VERSION  = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' macos/Resources/Info.plist 2>/dev/null || echo 0.1.0)
GO       = GOTOOLCHAIN=auto go
LDFLAGS  = -s -w -X main.version=$(VERSION)
# `make release` builds the Swift side optimized; everything else is a debug build.
CONFIG  ?= debug
SWIFT_BIN    = macos/.build/$(CONFIG)/Dial
DIAL_APP     = dist/Dial.app
SETTINGS_APP = dist/Dial Settings.app
# "Dial Local Signing" once `make signing-identity` made it, else ad hoc.
SIGN_ID = $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"Dial Local Signing"' && echo "Dial Local Signing" || echo -)
# Wails links the webview through cgo: built for the macOS Info.plist names.
export CGO_CFLAGS  = -O2 -mmacosx-version-min=13.0
export CGO_LDFLAGS = -mmacosx-version-min=13.0
MINGW = x86_64-w64-mingw32-g++

.PHONY: all build test test-scroll fmt core cli macos settings install run release windows signing-identity icon clean

all: build
build: core cli macos settings

test:
	$(GO) vet ./...
	$(GO) test ./...
	cd macos && swift test

# Drags the real ring of a freshly built dial over real apps, on this Mac. It
# takes over the pointer for about a minute: don't touch the mouse. It needs
# Accessibility for the terminal and the dial, and Screen Recording for the
# terminal for the scrollback check. ARGS='--only chrome,native' narrows it.
test-scroll: run
	macos/.build/$(CONFIG)/ScrollTest $(ARGS)

fmt:
	gofmt -w core cmd settings

core:
	$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o .build/dial-core ./cmd/dial-core

cli:
	$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o .build/dial-cli ./cmd/dial-cli

# dist/Dial.app: the Swift dial with dial-core next to it in Contents/MacOS.
macos: core
	cd macos && swift build -c $(CONFIG)
	rm -rf "$(DIAL_APP)"
	mkdir -p "$(DIAL_APP)/Contents/MacOS" "$(DIAL_APP)/Contents/Resources"
	cp "$(SWIFT_BIN)" "$(DIAL_APP)/Contents/MacOS/Dial"
	cp .build/dial-core "$(DIAL_APP)/Contents/MacOS/dial-core"
	cp macos/Resources/Info.plist "$(DIAL_APP)/Contents/Info.plist"
	cp macos/Resources/AppIcon.icns "$(DIAL_APP)/Contents/Resources/"
	codesign --force --sign "$(SIGN_ID)" "$(DIAL_APP)"

# dist/Dial Settings.app: the pages are embedded in the binary.
settings:
	$(GO) build -tags production -trimpath -ldflags "$(LDFLAGS)" -o .build/settings/dial-settings ./settings
	rm -rf "$(SETTINGS_APP)"
	mkdir -p "$(SETTINGS_APP)/Contents/MacOS" "$(SETTINGS_APP)/Contents/Resources"
	cp .build/settings/dial-settings "$(SETTINGS_APP)/Contents/MacOS/Dial Settings"
	cp settings/build/darwin/Info.plist "$(SETTINGS_APP)/Contents/Info.plist"
	cp settings/build/darwin/AppIcon.icns "$(SETTINGS_APP)/Contents/Resources/"
	codesign --force --sign "$(SIGN_ID)" "$(SETTINGS_APP)"

# Both apps into /Applications, synced in place so a grant tied to the
# path survives.
install: macos settings
	mkdir -p "/Applications/Dial.app" "/Applications/Dial Settings.app"
	rsync -a --delete "$(DIAL_APP)/" "/Applications/Dial.app/"
	rsync -a --delete "$(SETTINGS_APP)/" "/Applications/Dial Settings.app/"
	codesign --force --sign "$(SIGN_ID)" "/Applications/Dial.app"
	codesign --force --sign "$(SIGN_ID)" "/Applications/Dial Settings.app"

# The old dial is given a moment to quit (open fails with -600 while
# Launch Services still sees it), and a core left behind goes with it.
run: macos settings
	pkill -x Dial || true
	pkill -f 'Dial.app/Contents/MacOS/dial-core' || true
	for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Dial >/dev/null || break; sleep 0.3; done
	open "$(DIAL_APP)"

release:
	$(MAKE) macos settings CONFIG=release
	rm -rf "dist/Dial-$(VERSION)-macos-$(shell uname -m).zip" dist/release
	mkdir -p "dist/release/Dial-$(VERSION)"
	cp -R "$(DIAL_APP)" "$(SETTINGS_APP)" "dist/release/Dial-$(VERSION)/"
	ditto -c -k --norsrc --keepParent "dist/release/Dial-$(VERSION)" "dist/Dial-$(VERSION)-macos-$(shell uname -m).zip"
	shasum -a 256 "dist/Dial-$(VERSION)-macos-$(shell uname -m).zip"

# dist/windows: the C++ dial through mingw-w64, the Go binaries cross-compiled.
windows:
	@command -v $(MINGW) >/dev/null || { echo "install mingw-w64 (brew install mingw-w64) to cross-compile the Windows dial"; exit 1; }
	mkdir -p dist/windows
	$(MINGW) -std=c++17 -municode -D_USE_MATH_DEFINES -O2 -Wall windows/src/main.cpp -o dist/windows/dial.exe \
		-static -lws2_32 -lgdiplus -lole32 -lshell32 -luser32 -lgdi32 -ldwmapi -lversion -luuid -ladvapi32
	GOOS=windows GOARCH=amd64 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o dist/windows/dial-core.exe ./cmd/dial-core
	GOOS=windows GOARCH=amd64 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o dist/windows/dial-cli.exe ./cmd/dial-cli
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $(GO) build -tags production -trimpath -ldflags "$(LDFLAGS) -H windowsgui" -o dist/windows/dial-settings.exe ./settings

# The app icon, from macos/Resources/icons/AppIcon.svg. What it makes is kept in
# the tree, so a build needs neither rsvg-convert (brew install librsvg) nor
# iconutil. The menu bar icon is drawn in code: macos/Sources/Dial/MenuBarIcon.swift.
ICON_SVG = macos/Resources/icons/AppIcon.svg
icon:
	rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		rsvg-convert -w $$s -h $$s $(ICON_SVG) -o .build/AppIcon.iconset/icon_$${s}x$${s}.png && \
		rsvg-convert -w $$((s * 2)) -h $$((s * 2)) $(ICON_SVG) -o .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png || exit 1; \
	done
	iconutil -c icns .build/AppIcon.iconset -o macos/Resources/AppIcon.icns
	cp macos/Resources/AppIcon.icns settings/build/darwin/AppIcon.icns
	rsvg-convert -w 256 -h 256 $(ICON_SVG) -o settings/assets/icon.png

# A self-signed identity to sign with instead of ad hoc, so the
# Accessibility and Microphone grants survive rebuilds.
signing-identity:
	Scripts/signing-identity.sh

clean:
	rm -rf .build dist macos/.build
