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
//     of $desktopLog; -Log *:stdout:100 emits to our pipe)
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
	args, env, err := buildXvncArgs(envMap(os.Environ()), runtime.GOARCH, statExists, hostname)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: %v\n", err)
		os.Exit(64)
	}
	if err := syscall.Exec(args[0], args, env); err != nil {
		fmt.Fprintf(os.Stderr, "kasm-xvnc: exec %s: %v\n", args[0], err)
		os.Exit(127)
	}
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

	home := env["HOME"]
	if home == "" {
		home = "/home/kasm-user"
	}
	osUser := env["KASM_OS_USER"]
	if osUser == "" {
		osUser = "kasm-user"
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
		"-Log", "*:stdout:100",
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
