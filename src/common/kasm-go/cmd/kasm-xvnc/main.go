// kasm-xvnc replaces the perl `vncserver` wrapper on the Kasm path.
//
// The 3119-line perl wrapper accounts for ~250-300 ms of the
// kasmvnc_invoke phase on Ubuntu Noble (perl interpreter cold start
// + dependency probes + xdpyinfo poll loop). This Go port mirrors
// the wrapper's observed argv output for the Kasm boot configuration
// and exec(3)'s Xvnc directly. No KasmVNC source change.
//
// Mirroring strategy: the argv list is a verbatim port of what
// `docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily` (perl
// wrapper) emits at boot, with $HOME / $KASM_OS_USER / VNC_RESOLUTION
// / MAX_FRAME_RATE / hostname substituted from env. We do NOT compute
// these args from kasmvnc.yaml — that's the perl wrapper's job and
// re-implementing it is the 3000-line scope this port deliberately
// scoped out.
//
// Out of scope vs the perl wrapper:
//   - vncserver -kill / -list / -clean (admin commands; not on the
//     boot path, kept in KasmVNC's standalone CLI)
//   - kasmvnc.yaml dynamic parsing (the static argv we emit already
//     subsumes the OOTB kasmvnc.yaml's effective config)
//   - multi-display lock files (container-init starts clean per boot)
//   - desktop log rotation (container-init's stdout takes the place
//     of $desktopLog; -Log *:stdout:30 emits to our pipe at INFO
//     level, matching the OOTB vncserver perl wrapper -- level 100
//     turns on per-frame DEBUG and floods the container journal)
//
// Full rationale, configurability-parity analysis (what the yaml
// bypass does and doesn't lose), and the argv re-capture procedure
// for KasmVNC version bumps: design/kasm-xvnc-perl-bypass.md.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
)

const xvncBinary = "/usr/bin/Xvnc"

// identitySnapshotPath is the root-owned identity snapshot that
// kasm-setup writes at boot, holding the effective post-rename
// KASM_OS_* values. It is the authoritative source for the container
// user's identity: a session process can rewrite its own KASM_OS_* env
// but not this root-owned file, so its values take precedence over the
// ambient env. Absent/unreadable file is a no-op.
const identitySnapshotPath = "/run/kasm/os-user.env"

// frameTookPrefix is the leading text of an Xvnc per-frame debug print
// ("TOTAL FRAME TOOK: %d\n") that's compiled into the KasmVNC binary
// at /usr/bin/Xvnc — it bypasses the `-Log` framework and goes straight
// to stdout, drowning every other log line in the container journal.
//
// TODO(KASMVNC-UPSTREAM): drop this filter (and revert kasm-xvnc to
// syscall.Exec) once Xvnc removes the printf — track the upstream fix
// so we don't carry this hack longer than necessary.
const frameTookPrefix = "TOTAL FRAME TOOK: "

func main() {
	envm := envMap(os.Environ())
	overlayIdentity(envm, identitySnapshotPath)
	args, env, err := buildXvncArgs(envm, runtime.GOARCH, statExists, hostname)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: %v\n", err)
		os.Exit(64)
	}
	os.Exit(runXvnc(args, env))
}

// runXvnc forks Xvnc with its stdout piped through a line filter that
// drops the per-frame "TOTAL FRAME TOOK:" debug spam. stderr is left
// inherited so KasmVNC's real diagnostics still surface unchanged.
// We also forward common termination signals — container-init sends
// SIGTERM on shutdown and we want Xvnc to see it directly so it
// finishes its EncodeManager flush.
func runXvnc(args, env []string) int {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = env
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: stdout pipe: %v\n", err)
		return 127
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: start %s: %v\n", args[0], err)
		return 127
	}

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT)
	go func() {
		for s := range sigs {
			if cmd.Process != nil {
				_ = cmd.Process.Signal(s)
			}
		}
	}()

	filterFrameTook(stdout, os.Stdout)

	if err := cmd.Wait(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				return 128 + int(ws.Signal())
			}
			return ee.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "kasm-xvnc: wait: %v\n", err)
		return 127
	}
	return 0
}

// filterFrameTook copies r to w line-by-line, dropping any line whose
// payload starts with frameTookPrefix. Buffer size is bumped from the
// 64KB default so a single huge log line can't deadlock the pipe.
func filterFrameTook(r io.Reader, w io.Writer) {
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			if !startsWith(line, frameTookPrefix) {
				_, _ = w.Write(line)
			}
		}
		if err != nil {
			return
		}
	}
}

func startsWith(b []byte, s string) bool {
	if len(b) < len(s) {
		return false
	}
	for i := 0; i < len(s); i++ {
		if b[i] != s[i] {
			return false
		}
	}
	return true
}

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

// overlayIdentity merges KASM_OS_* assignments from the snapshot file at
// path into env, overriding any ambient values (the file is the trusted
// source; see identitySnapshotPath). A missing or unreadable file is a
// no-op, so buildXvncArgs falls back to env + defaults exactly as
// before. Only KASM_OS_* keys are honoured — anything else in the file
// is ignored so a malformed snapshot can't inject unrelated Xvnc env.
func overlayIdentity(env map[string]string, path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		i := strings.IndexByte(line, '=')
		if i <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:i])
		if !strings.HasPrefix(key, "KASM_OS_") {
			continue
		}
		env[key] = strings.TrimSpace(line[i+1:])
	}
}

func statExists(path string) bool { _, err := os.Stat(path); return err == nil }
func hostname() string            { h, _ := os.Hostname(); return h }

// buildXvncArgs mirrors the OOTB perl wrapper's emitted argv. Each
// `-Foo X` triple here corresponds to a key in kasmvnc.yaml's
// effective config + perl-wrapper defaults; we hard-code the
// observed values. Inputs are factored out so tests can pin every
// conditional flag independently of the host filesystem.
func buildXvncArgs(env map[string]string, arch string, fileExists func(string) bool, host func() string) ([]string, []string, error) {
	display := env["DISPLAY"]
	if display == "" {
		display = ":1"
	}
	if !strings.HasPrefix(display, ":") {
		display = ":" + display
	}

	osUser := env["KASM_OS_USER"]
	if osUser == "" {
		osUser = "kasm-user"
	}
	// Resolution order matches the unit-file expansion contract:
	// KASM_OS_HOME wins, else /home/$KASM_OS_USER, else $HOME, else
	// /home/kasm-user. When the boot snapshot exists, overlayIdentity has
	// already populated KASM_OS_HOME/KASM_OS_USER here, so the first
	// branch normally wins; the fallbacks only matter pre-snapshot (e.g.
	// a downstream image that runs Xvnc without kasm-setup). The middle
	// step matters when the operator sets
	// only KASM_OS_USER — kasm-os-user-rename moved the home dir to
	// /home/$KASM_OS_USER but the dockerfile baked HOME=/home/kasm-user
	// into PID 1's env, so falling through to env["HOME"] would chdir
	// into a path that no longer exists.
	home := env["KASM_OS_HOME"]
	if home == "" {
		if osUser != "kasm-user" {
			home = "/home/" + osUser
		} else if h := env["HOME"]; h != "" {
			home = h
		} else {
			home = "/home/kasm-user"
		}
	}
	resolution := env["VNC_RESOLUTION"]
	if resolution == "" {
		resolution = "1024x768"
	}
	frameRate := env["MAX_FRAME_RATE"]
	if frameRate == "" {
		frameRate = "24"
	}
	depth := env["VNC_COL_DEPTH"]
	if depth == "" {
		depth = "24"
	}
	wsPort := env["NO_VNC_PORT"]
	if wsPort == "" {
		wsPort = "6901"
	}
	kasmvncPath := env["KASM_VNC_PATH"]
	if kasmvncPath == "" {
		kasmvncPath = "/usr/share/kasmvnc"
	}
	drinode := env["DRINODE"]
	if drinode == "" {
		drinode = "/dev/dri/renderD128"
	}

	cert := home + "/.vnc/self.pem"
	rfbauth := home + "/.vnc/passwd"
	xauth := home + "/.Xauthority"
	kasmpasswd := home + "/.kasmpasswd"

	desktopName := fmt.Sprintf("%s%s (%s)", host(), display, osUser)

	// Argv ported verbatim from `kasmweb/core-ubuntu-noble:1.18.0-rolling-daily`'s
	// Xvnc invocation (see design/spike/runs/probe-xvnc.stdout for the
	// captured baseline). Order preserved — the perl wrapper emits
	// kasmvnc.yaml-derived args first, then defaults, then operator
	// overrides; later args override earlier (e.g. -FrameRate=24 then
	// -FrameRate 60 — Xvnc's last-wins parsing applies).
	args := []string{
		xvncBinary, display,
		"-drinode", drinode,
		"-depth", depth,
		"-httpd", kasmvncPath + "/www",
		"-sslOnly",
		"-FrameRate=" + frameRate,
		"-BlacklistThreshold=0",
		"-FreeKeyMappings",
		"-PreferBandwidth",
		"-DynamicQualityMin=4",
		"-DynamicQualityMax=7",
		"-DLP_ClipDelay=0",
	}

	if isEnabled(env, "KASM_SVC_PRINTER") {
		args = append(args, "-UnixRelay", "printer:/tmp/printer")
	}
	if isEnabled(env, "KASM_SVC_SMARTCARD") {
		args = append(args, "-UnixRelay", "smartcard:/tmp/smartcard")
	}

	args = append(args,
		"-interface", "0.0.0.0",
		"-websocketPort", wsPort,
		"-VideoOutTime", "3",
		"-VideoScaling", "2",
		"-MaxIdleTime", "0",
		"-VideoTime", "5",
		"-AllowOverride", "AcceptPointerEvents",
		"-DLP_KeyRateLimit", "0",
		"-BlacklistThreshold", "5",
		"-RectThreads", "0",
		"-DLP_RegionAllowRelease", "0",
		"-JpegVideoQuality", "-1",
		"-UseIPv6", "1",
		"-UseIPv4", "1",
		"-ScrollDetectLimit", "25",
		"-MaxDisconnectionTime", "0",
		"-MaxConnectionTime", "0",
		"-AcceptCutText", "1",
		"-KasmPasswordFile", kasmpasswd,
		"-PublicIP", "127.0.0.1",
		"-CompareFB", "2",
		"-WebpEncodingTime", "30",
		"-QueryConnectTimeout", "10",
		"-DLP_RegionAllowClick", "0",
		"-DLP_ClipTypes", "chromium/x-web-custom-data,text/html,image/png",
		"-DLP_ClipDelay", "0",
		"-DynamicQualityMax", "8",
		"-MaxVideoResolution", "1920x1080",
		"-geometry", resolution,
		"-AcceptPointerEvents", "1",
		"-IdleTimeout", "0",
		"-WebpVideoQuality", "-1",
		"-RawKeyboard", "0",
		"-VideoArea", "45",
		"-AcceptKeyEvents", "1",
		"-DLP_ClipAcceptMax", "0",
		"-IgnoreClientSettingsKasm", "0",
		"-PrintVideoArea", "0",
		"-Log", "*:stdout:30",
		"-BlacklistTimeout", "10",
		"-DisconnectClients", "0",
		"-FrameRate", "60",
		"-SendPrimary", "0",
		"-DLP_Log", "off",
		"-AcceptSetDesktopSize", "1",
		"-DynamicQualityMin", "7",
		"-SendCutText", "1",
		"-TreatLossless", "10",
		"-cert", cert,
		"-udpFullFrameFrequency", "0",
		"-AvoidShiftNumLock", "0",
		"-ImprovedHextile", "1",
		"-DLP_ClipSendMax", "0",
		"-http-header", "Cross-Origin-Embedder-Policy=require-corp",
		"-http-header", "Cross-Origin-Opener-Policy=same-origin",
		"-QueryConnect", "0",
		"-fp", "/usr/share/fonts/X11//misc,/usr/share/fonts/X11//Type1",
		"-auth", xauth,
		"-key", cert,
		"-desktop", desktopName,
		"-rfbport", "5901",
		"-rfbauth", rfbauth,
		"-rfbwait", "30000",
	)

	// Operator-supplied extras (matches the bash chain's word-splitting).
	for _, key := range []string{"VNCOPTIONS", "KASM_SVC_SEND_CUT_TEXT", "KASM_SVC_ACCEPT_CUT_TEXT"} {
		if v := env[key]; v != "" {
			args = append(args, strings.Fields(v)...)
		}
	}

	// aarch64 LD_PRELOAD workaround — Xvnc unwind-table resolution bug
	// under multi-threaded fork on glibc systems where libgcc isn't
	// already in the link map.
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
