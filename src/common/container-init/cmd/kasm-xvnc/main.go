// kasm-xvnc replaces the perl `vncserver` wrapper on the Kasm path.
//
// The 3119-line perl wrapper accounts for ~250-300 ms of the
// kasmvnc_invoke phase on Ubuntu Noble (perl interpreter cold start
// + dependency probes + xdpyinfo poll loop) — see
// design/cold-start-perf-and-memory.md § "Where the 573 ms in
// kasmvnc_invoke actually goes". Phase 4.4 ports the wrapper's
// ConstructXvncCmd to Go, builds the same Xvnc argv, and exec(3)s
// Xvnc directly. No KasmVNC source change.
//
// Out of scope vs the perl wrapper:
//   - xauth cookie file generation (Kasm uses kasmvncpasswd, not xauth)
//   - desktop log rotation (container-init's stdout takes the place
//     of $desktopLog)
//   - multi-display lock files (container-init starts clean per boot)
//   - vncserver -kill / -list / -clean (those are admin commands;
//     not on the boot path)
//   - kasmvnc.yaml config-file parsing (Kasm passes every option
//     explicitly via env vars / CLI flags; the perl wrapper's
//     ConfigToCmd path is unused on the Kasm boot path)
//
// Standalone-CLI users (KasmVNC outside a Kasm container) keep using
// the perl wrapper as today.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
	"syscall"
)

const xvncBinary = "/usr/bin/Xvnc"

func main() {
	args, env, err := buildXvncArgs(envMap(os.Environ()), runtime.GOARCH, statExists)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: %v\n", err)
		os.Exit(64)
	}
	// exec(3) replaces our process image so container-init's
	// supervisor tracks the Xvnc PID directly. cmd.Process.Pid
	// stays valid; no extra fork hop.
	if err := syscall.Exec(args[0], args, env); err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: exec %s: %v\n", args[0], err)
		os.Exit(127)
	}
}

// envMap turns os.Environ()-style "K=V" entries into a map. Empty K
// or missing "=" is dropped.
func envMap(env []string) map[string]string {
	out := make(map[string]string, len(env))
	for _, kv := range env {
		i := strings.IndexByte(kv, '=')
		if i <= 0 {
			continue
		}
		out[kv[:i]] = kv[i+1:]
	}
	return out
}

// statExists is the production filesystem probe. Tests pass their
// own to control the aarch64 LD_PRELOAD path deterministically.
func statExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// buildXvncArgs produces the (argv, env) pair Xvnc should be exec'd
// with. Mirrors what perl `vncserver`'s ConstructXvncCmd would emit
// for the Kasm bash invocation in src/common/startup_scripts/
// vnc_startup.sh § start_kasmvnc.
//
// Inputs are factored out so tests can pin every conditional flag
// independently of the test host's filesystem and architecture.
func buildXvncArgs(env map[string]string, arch string, fileExists func(string) bool) ([]string, []string, error) {
	display := env["DISPLAY"]
	if display == "" {
		display = ":1"
	}
	if !strings.HasPrefix(display, ":") {
		display = ":" + display
	}

	args := []string{xvncBinary, display}

	if env["HW3D"] != "" {
		args = append(args, "-hw3d")
	}

	drinode := env["DRINODE"]
	if drinode == "" {
		drinode = "/dev/dri/renderD128"
	}
	args = append(args, "-drinode", drinode)

	if v := env["VNC_COL_DEPTH"]; v != "" {
		args = append(args, "-depth", v)
	}
	if v := env["VNC_RESOLUTION"]; v != "" {
		args = append(args, "-geometry", v)
	}
	if v := env["NO_VNC_PORT"]; v != "" {
		args = append(args, "-websocketPort", v)
	}
	if v := env["KASM_VNC_PATH"]; v != "" {
		args = append(args, "-httpd", v+"/www")
	}

	// -select-de is a perl-wrapper-only flag (xstartup desktop
	// selector). Container-init's window-manager.service runs the
	// DE as its own unit, so the flag is meaningless on this path
	// and Xvnc rejects it as an unknown option. Documented drop
	// per the brief; standalone-CLI users keep using vncserver.
	args = append(args,
		"-sslOnly",
		"-interface", "0.0.0.0",
		"-BlacklistThreshold=0",
		"-FreeKeyMappings",
		// Xvnc's default `-SecurityTypes VncAuth` reads ~/.vnc/passwd
		// (rfb-style hashed) — that file isn't written by `kasmvncpasswd`
		// (which only produces ~/.kasmpasswd). The matching scheme is
		// `Plain`, plus an explicit `-PlainUsers` allow-list.
		"-SecurityTypes", "Plain",
	)
	plainUser := env["KASM_OS_USER"]
	if plainUser == "" {
		plainUser = "kasm-user"
	}
	args = append(args, "-PlainUsers", plainUser)

	// SSL cert. KasmVNC's `-cert` defaults to empty; without it,
	// `-sslOnly` Xvnc accepts the TCP connection then drops it during
	// TLS handshake (no cert/key pair to present). The perl wrapper's
	// ConstructXvncCmd resolves this from $HOME/.vnc/self.pem;
	// kasm-setup.service writes that file at boot from the baked
	// /etc/kasm/self-default.pem (or KASM_TLS_CERT_PATH override).
	homeDir := env["HOME"]
	if homeDir == "" {
		homeDir = "/home/kasm-user"
	}
	certPath := homeDir + "/.vnc/self.pem"
	if fileExists(certPath) {
		args = append(args, "-cert", certPath)
	}
	if v := env["MAX_FRAME_RATE"]; v != "" {
		args = append(args, "-FrameRate="+v)
	}

	// UnixRelay flags follow the bash's per-service toggles.
	// Default-on (set to "0" to suppress).
	if isEnabled(env, "KASM_SVC_PRINTER") {
		args = append(args, "-UnixRelay", "printer:/tmp/printer")
	}
	if isEnabled(env, "KASM_SVC_SMARTCARD") {
		args = append(args, "-UnixRelay", "smartcard:/tmp/smartcard")
	}

	// Operator-supplied extras. VNCOPTIONS is split on whitespace
	// (matching the bash's word-splitting behaviour); quoted args
	// inside the env var aren't supported — operators with that need
	// install a kasmvnc.yaml.
	for _, key := range []string{"VNCOPTIONS", "KASM_SVC_SEND_CUT_TEXT", "KASM_SVC_ACCEPT_CUT_TEXT"} {
		if v := env[key]; v != "" {
			args = append(args, strings.Fields(v)...)
		}
	}

	// On aarch64 the bash conditionally LD_PRELOADs libgcc_s. The
	// underlying Xvnc bug it works around (libgcc unwind table
	// resolution under multi-threaded fork) only manifests on aarch64
	// glibc systems where libgcc isn't already in the link map.
	out := os.Environ()
	if arch == "arm64" {
		const libgcc = "/lib/aarch64-linux-gnu/libgcc_s.so.1"
		if fileExists(libgcc) {
			out = append(out, "LD_PRELOAD="+libgcc)
		}
	}
	return args, out, nil
}

// isEnabled treats unset / empty as ON (matches the bash default
// "${KASM_SVC_X:-1}" idiom). "0" / "false" / "no" / "off" suppresses.
func isEnabled(env map[string]string, key string) bool {
	v, ok := env[key]
	if !ok || v == "" {
		return true
	}
	switch strings.ToLower(v) {
	case "0", "false", "no", "off":
		return false
	}
	return true
}
