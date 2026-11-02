// dial-cli tries the core's pieces from a terminal, without a dial:
//
//	dial-cli decide "switch to safari" --apps Safari,Slack,Finder
//	dial-cli asr recording.pcm        # 16 kHz 16-bit mono PCM
//	dial-cli test                     # the speech engine and Jev credentials
//	dial-cli ring                     # the learned ring
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/yangxin0/dial/core/asr"
	"github.com/yangxin0/dial/core/config"
	"github.com/yangxin0/dial/core/protocol"
	"github.com/yangxin0/dial/core/ring"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cfg, err := config.Load(config.Path())
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
	}
	ctx := context.Background()
	switch os.Args[1] {
	case "decide":
		// --apps may come before or after the sentence.
		names, words := "Finder,Safari,Slack", []string{}
		args := os.Args[2:]
		for i := 0; i < len(args); i++ {
			switch {
			case (args[i] == "--apps" || args[i] == "-apps") && i+1 < len(args):
				names = args[i+1]
				i++
			case strings.HasPrefix(args[i], "--apps="):
				names = strings.TrimPrefix(args[i], "--apps=")
			default:
				words = append(words, args[i])
			}
		}
		if len(words) == 0 {
			usage()
		}
		var apps []protocol.App
		for _, n := range strings.Split(names, ",") {
			if n = strings.TrimSpace(n); n != "" {
				apps = append(apps, protocol.App{ID: strings.ToLower(n), Name: n, Running: true})
			}
		}
		result := cfg.Decider().Decide(ctx, strings.Join(words, " "), apps)
		print(result.Message())
	case "asr":
		if len(os.Args) < 3 {
			usage()
		}
		engine, ok := cfg.ActiveEngine()
		if !ok || !engine.Configured() {
			fail("the speech engine is not set up in " + config.Path())
		}
		f, err := os.Open(os.Args[2])
		if err != nil {
			fail(err.Error())
		}
		defer f.Close()
		rec, err := asr.Start(ctx, engine, cfg.Voice.Hotwords)
		if err != nil {
			fail(err.Error())
		}
		go func() {
			buf := make([]byte, asr.ChunkBytes)
			for {
				n, err := io.ReadFull(f, buf)
				if n > 0 && err == nil {
					rec.Send(buf[:n])
					time.Sleep(200 * time.Millisecond)
					continue
				}
				rec.Finish(buf[:n])
				return
			}
		}()
		for ev := range rec.Events() {
			if ev.Err != nil {
				fail(ev.Err.Error())
			}
			if ev.Final {
				fmt.Println(ev.Text)
			} else {
				fmt.Fprintln(os.Stderr, "…", ev.Text)
			}
		}
	case "test":
		engine, ok := cfg.ActiveEngine()
		if ok && engine.Configured() {
			took, logid, err := asr.Test(ctx, engine)
			report("voice", took, err, logid)
		} else {
			fmt.Println("voice: not set up")
		}
		if jc := cfg.JevClient(); jc.Configured() {
			took, err := jc.Test(ctx)
			report("jev", took, err, "")
		} else {
			fmt.Println("jev: not set up (rules decide)")
		}
	case "ring":
		r, err := ring.Load(config.RingPath())
		if err != nil {
			fail(err.Error())
		}
		r.HalfLifeDays = cfg.Ring.HalfLifeDays
		entries := r.Entries()
		ids := make([]string, 0, len(entries))
		for id := range entries {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return entries[ids[i]].Count > entries[ids[j]].Count })
		for _, id := range ids {
			e := entries[id]
			fmt.Printf("%-40s %-24s %6.2f  %s\n", id, e.Name, e.Count, e.Last.Local().Format("2006-01-02 15:04"))
		}
	default:
		usage()
	}
}

func report(what string, took time.Duration, err error, logid string) {
	if err != nil {
		fmt.Printf("%s: FAILED %v\n", what, err)
		return
	}
	extra := ""
	if logid != "" {
		extra = " (logid " + logid + ")"
	}
	fmt.Printf("%s: ok in %d ms%s\n", what, took.Milliseconds(), extra)
}

func print(v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(b))
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  dial-cli decide "switch to safari" [--apps Safari,Slack,Finder]
  dial-cli asr recording.pcm
  dial-cli test
  dial-cli ring`)
	os.Exit(2)
}
