//go:build !windows

package main

import (
	"errors"
	"syscall"
)

// parentAlive: a signal 0 reaches a live process (EPERM means it exists
// but is someone else's).
func parentAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
