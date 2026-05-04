// spike-helper is the test program used by Phase 2 probe F.
//
// Modes:
//
//   -mode native — consume the listening fd inherited from container-init
//                  via the sd_listen_fds protocol (fd 3, LISTEN_FDS=1).
//                  Falls back to listening on -listen when no inherited
//                  fd is present, so the binary remains usable for
//                  manual testing.
//
//   -mode proxy  — bind -listen directly. container-init drives the
//                  public socket and forwards bytes here.
//
// Common: accept connections in a loop and echo bytes back. Tracks a
// per-process counter; if SPIKE_HELPER_DIE_AFTER=N is set with N>0,
// exits with status 1 after the Nth accepted connection so probe F
// can observe Restart=on-failure.
//
// Removed in Phase 4 once the real Kasm units replace the spike set.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

func main() {
	mode := flag.String("mode", "native", "native | proxy")
	listen := flag.String("listen", "", "fallback/private listen address (host:port or /unix/path)")
	flag.Parse()

	log.SetFlags(0)
	log.SetPrefix(fmt.Sprintf("spike-helper(%s,pid=%d): ", *mode, os.Getpid()))

	var ln net.Listener
	var err error

	switch *mode {
	case "native":
		ln, err = nativeListener(*listen)
	case "proxy":
		if *listen == "" {
			log.Fatalf("proxy mode requires -listen")
		}
		ln, err = listenAddr(*listen)
	default:
		log.Fatalf("unknown -mode %q", *mode)
	}
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("ready on %s", ln.Addr())

	dieAfter := getEnvInt("SPIKE_HELPER_DIE_AFTER", 0)

	var connID int64
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatalf("accept: %v", err)
		}
		id := atomic.AddInt64(&connID, 1)
		log.Printf("conn %d from %s", id, conn.RemoteAddr())
		go handle(conn, id)
		if dieAfter > 0 && int(id) >= dieAfter {
			// Give the in-flight handler a moment to finish then die
			// so probe F can observe Restart=on-failure.
			time.Sleep(50 * time.Millisecond)
			log.Printf("dying after %d conns (SPIKE_HELPER_DIE_AFTER)", id)
			os.Exit(1)
		}
	}
}

// nativeListener returns the listener inherited from container-init
// via sd_listen_fds (fd 3). LISTEN_PID is checked when set; an unset
// or zero LISTEN_PID is treated as "trust the fds" (the standard
// fallback for parents that can't pre-set the child PID).
func nativeListener(fallback string) (net.Listener, error) {
	nfds := getEnvInt("LISTEN_FDS", 0)
	if nfds <= 0 {
		if fallback == "" {
			return nil, fmt.Errorf("LISTEN_FDS unset and no -listen fallback")
		}
		log.Printf("no inherited fds; falling back to -listen %s", fallback)
		return listenAddr(fallback)
	}
	if pid := getEnvInt("LISTEN_PID", 0); pid != 0 && pid != os.Getpid() {
		return nil, fmt.Errorf("LISTEN_PID=%d != getpid()=%d", pid, os.Getpid())
	}
	f := os.NewFile(3, "listener")
	if f == nil {
		return nil, fmt.Errorf("fd 3 is not a valid file")
	}
	ln, err := net.FileListener(f)
	if err != nil {
		return nil, fmt.Errorf("FileListener(fd 3): %w", err)
	}
	// Close our copy of the *os.File once net has dup'd it.
	_ = f.Close()
	return ln, nil
}

func listenAddr(addr string) (net.Listener, error) {
	if len(addr) > 0 && addr[0] == '/' {
		_ = os.Remove(addr)
		return net.Listen("unix", addr)
	}
	return net.Listen("tcp", addr)
}

func handle(conn net.Conn, id int64) {
	defer conn.Close()
	// Echo with a small banner so probes can grep for it.
	fmt.Fprintf(conn, "spike-helper pid=%d conn=%d\n", os.Getpid(), id)
	_, _ = io.Copy(conn, conn)
}

func getEnvInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
