// Dial Settings: one window of plain HTML pages that set up the speech
// engine and Jev, tune the dial, and show the learned ring, hosted with
// Wails the way magpie and Fluent host theirs. It edits the config file
// dial-core reads before every recording.
package main

import (
	"embed"
	"io/fs"
	"log"
	"runtime"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed assets
var assets embed.FS

//go:embed assets/icon.png
var icon []byte

// version is set by the Makefile (-X main.version=…).
var version = "dev"

func main() {
	pages, _ := fs.Sub(assets, "assets")
	h := newHost(version)
	app := application.New(application.Options{
		Name:        "Dial Settings",
		Description: "Settings for the Dial",
		Icon:        icon,
		Assets:      application.AssetOptions{Handler: h.handler(pages)},
		Mac: application.MacOptions{
			ActivationPolicy: application.ActivationPolicyRegular,
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
		ErrorHandler: func(err error) { log.Println("dial-settings:", err) },
	})
	menu := application.DefaultApplicationMenu()
	if help := menu.FindByRole(application.HelpMenu); help != nil {
		help.GetSubmenu().Clear()
		help.GetSubmenu().Add("Dial on GitHub").OnClick(func(*application.Context) {
			app.Browser.OpenURL(repository)
		})
	}
	app.Menu.Set(menu)

	options := application.WebviewWindowOptions{
		Name:      "main",
		Title:     "Dial Settings",
		URL:       "/",
		Width:     720,
		Height:    600,
		MinWidth:  600,
		MinHeight: 460,
	}
	if runtime.GOOS == "darwin" {
		options.Mac = application.MacWindow{TitleBar: application.MacTitleBarHiddenInset}
	}
	app.Window.NewWithOptions(options)
	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
