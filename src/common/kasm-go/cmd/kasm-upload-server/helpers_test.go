package main

import (
	"net/http"
	"os"
	"syscall"
	"testing"
)

func mustStatus(t *testing.T, resp *http.Response, want int) {
	t.Helper()
	if resp.StatusCode != want {
		t.Fatalf("HTTP %d, want %d", resp.StatusCode, want)
	}
}

func mustBody(t *testing.T, got []byte, want string) {
	t.Helper()
	if string(got) != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
}

func mustHeader(t *testing.T, resp *http.Response, key, want string) {
	t.Helper()
	if got := resp.Header.Get(key); got != want {
		t.Fatalf("header %s = %q, want %q", key, got, want)
	}
}

// dupTo copies f's fd onto target using dup2, closing whatever was
// previously open on target. The caller is responsible for restoring
// any fd they displaced.
func dupTo(f *os.File, target int) error {
	return syscall.Dup2(int(f.Fd()), target)
}

// fdSave duplicates fd into a fresh descriptor and returns it; -1 if
// fd is not currently open. Pair with fdRestore in a t.Cleanup so a
// test that overwrites a stdlib-owned fd (test runner uses fd 3 for
// its log file) leaves the runtime intact.
func fdSave(fd int) int {
	saved, err := syscall.Dup(fd)
	if err != nil {
		return -1
	}
	return saved
}

func fdRestore(target, saved int) {
	if saved < 0 {
		return
	}
	_ = syscall.Dup2(saved, target)
	_ = syscall.Close(saved)
}
