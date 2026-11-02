//go:build windows

package main

import "syscall"

const stillActive = 259

// parentAlive asks the process for its exit code: STILL_ACTIVE while it
// runs.
func parentAlive(pid int) bool {
	h, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return false
	}
	return code == stillActive
}
