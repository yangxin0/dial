// dial-core is the dial's shared half: it listens on the loopback
// interface for a native dial, records through the speech engine, decides
// what was meant, and keeps the ring learned. The native dial starts it.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/ring"
	"github.com/yangxin0/dial/core/server"
)

// version is set by the Makefile (-X main.version=…).
var version = "dev"

// watchParent ends the core once the dial that started it is gone, so a
// dial killed outright leaves no core behind.
func watchParent(pid int, stop func()) {
	for {
		time.Sleep(2 * time.Second)
		if !parentAlive(pid) {
			log.Printf("the dial (pid %d) is gone, exiting", pid)
			stop()
			return
		}
	}
}

func main() {
	port := flag.Int("port", 0, "listen on this port instead of the config's")
	parent := flag.Int("parent", 0, "exit once this process is gone: the dial that started this core")
	configPath := flag.String("config", "", "the config file (default ~/.config/dial/config.json)")
	showVersion := flag.Bool("version", false, "print the version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	path := *configPath
	if path == "" {
		path = config.Path()
	}
	if err := config.Ensure(path); err != nil {
		log.Printf("config: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		log.Printf("config: %v", err)
	}
	listenOn := cfg.Port
	if *port != 0 {
		listenOn = *port
	}
	r, err := ring.Load(config.RingPath())
	if err != nil {
		log.Printf("ring: %v", err)
	}
	r.HalfLifeDays = cfg.Ring.HalfLifeDays
	ln, err := server.Listen(listenOn)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("dial-core %s listening on %s, config %s", version, ln.Addr(), path)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *parent > 0 {
		go watchParent(*parent, stop)
	}
	s := server.New(server.Options{
		Version: version,
		Config:  func() (*config.Config, error) { return config.Load(path) },
		Ring:    r,
	})
	if err := s.Serve(ctx, ln); err != nil {
		log.Fatal(err)
	}
}
