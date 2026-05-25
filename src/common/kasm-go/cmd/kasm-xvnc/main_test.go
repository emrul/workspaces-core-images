package main

import (
	"strings"
	"testing"
)

// fakeStat is the test stand-in for os.Stat. Returns a probe that
// reports paths in the supplied set as existing.
func fakeStat(present ...string) func(string) bool {
	set := make(map[string]bool, len(present))
	for _, p := range present {
		set[p] = true
	}
	return func(p string) bool { return set[p] }
}

func fakeHost() string { return "container1" }

// argSeq finds an `[a, b]` adjacent pair in args; useful for checking
// `-Foo bar` flag pairs without knowing the exact slice index.
func hasFlagValue(args []string, flag, value string) bool {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func TestBuildXvncArgsMatchesOOTB(t *testing.T) {
	// Spot-check the argv shape mirrors the perl wrapper's emitted
	// OOTB invocation. Full byte-for-byte match isn't worth the test
	// brittleness; we verify the structurally important pieces.
	env := map[string]string{
		"DISPLAY":        ":1",
		"VNC_RESOLUTION": "1280x800",
		"MAX_FRAME_RATE": "30",
		"NO_VNC_PORT":    "6901",
		"KASM_OS_USER":   "alice",
		"HOME":           "/home/alice",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat(), fakeHost)
	if err != nil {
		t.Fatalf("buildXvncArgs: %v", err)
	}
	checks := []struct {
		desc string
		ok   bool
	}{
		{"argv[0] is Xvnc", args[0] == "/usr/bin/Xvnc"},
		{"display normalised to :1", args[1] == ":1"},
		{"-sslOnly present", hasFlag(args, "-sslOnly")},
		{"-cert points at $HOME/.vnc/self.pem",
			hasFlagValue(args, "-cert", "/home/alice/.vnc/self.pem")},
		{"-key points at $HOME/.vnc/self.pem",
			hasFlagValue(args, "-key", "/home/alice/.vnc/self.pem")},
		{"-rfbauth points at $HOME/.vnc/passwd (sentinel)",
			hasFlagValue(args, "-rfbauth", "/home/alice/.vnc/passwd")},
		{"-KasmPasswordFile points at $HOME/.kasmpasswd",
			hasFlagValue(args, "-KasmPasswordFile", "/home/alice/.kasmpasswd")},
		{"-auth points at $HOME/.Xauthority",
			hasFlagValue(args, "-auth", "/home/alice/.Xauthority")},
		{"-geometry uses VNC_RESOLUTION",
			hasFlagValue(args, "-geometry", "1280x800")},
		{"-FrameRate=NN uses MAX_FRAME_RATE",
			hasFlag(args, "-FrameRate=30")},
		{"-websocketPort uses NO_VNC_PORT",
			hasFlagValue(args, "-websocketPort", "6901")},
		{"-desktop has hostname:display (user)",
			hasFlagValue(args, "-desktop", "container1:1 (alice)")},
		{"-rfbport 5901 (perl-wrapper default)",
			hasFlagValue(args, "-rfbport", "5901")},
		{"-Log *:stdout:30 emits to container-init's pipe at INFO level",
			hasFlagValue(args, "-Log", "*:stdout:30")},
		{"-PublicIP 127.0.0.1",
			hasFlagValue(args, "-PublicIP", "127.0.0.1")},
		{"UnixRelay printer enabled by default",
			hasFlagValue(args, "-UnixRelay", "printer:/tmp/printer")},
		{"UnixRelay smartcard enabled by default",
			hasFlagValue(args, "-UnixRelay", "smartcard:/tmp/smartcard")},
		{"CORS COEP header",
			hasFlagValue(args, "-http-header", "Cross-Origin-Embedder-Policy=require-corp")},
		{"CORS COOP header",
			hasFlagValue(args, "-http-header", "Cross-Origin-Opener-Policy=same-origin")},
	}
	for _, c := range checks {
		if !c.ok {
			t.Errorf("FAIL: %s\nargs: %v", c.desc, args)
		}
	}
}

func TestBuildXvncArgsDefaults(t *testing.T) {
	args, _, err := buildXvncArgs(map[string]string{}, "amd64", fakeStat(), fakeHost)
	if err != nil {
		t.Fatalf("buildXvncArgs: %v", err)
	}
	if args[1] != ":1" {
		t.Errorf("default DISPLAY = %q, want :1", args[1])
	}
	if !hasFlagValue(args, "-geometry", "1024x768") {
		t.Errorf("default -geometry should be 1024x768: %v", args)
	}
	if !hasFlagValue(args, "-cert", "/home/kasm-user/.vnc/self.pem") {
		t.Errorf("default cert path wrong: %v", args)
	}
	if !hasFlagValue(args, "-desktop", "container1:1 (kasm-user)") {
		t.Errorf("default -desktop wrong: %v", args)
	}
}

func TestBuildXvncArgsToggleSuppress(t *testing.T) {
	env := map[string]string{
		"KASM_SVC_PRINTER":   "0",
		"KASM_SVC_SMARTCARD": "false",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat(), fakeHost)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-UnixRelay" {
			t.Errorf("UnixRelay flag leaked when toggle suppressed: %v", args[i:i+2])
		}
	}
}

func TestBuildXvncArgsVNCOPTIONSPassThrough(t *testing.T) {
	env := map[string]string{
		"VNCOPTIONS":             "-DLP_Region_Allow_List=*",
		"KASM_SVC_SEND_CUT_TEXT": "-someExtra",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat(), fakeHost)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-DLP_Region_Allow_List=*") {
		t.Errorf("VNCOPTIONS not passed through: %v", args)
	}
	if !strings.Contains(joined, "-someExtra") {
		t.Errorf("KASM_SVC_SEND_CUT_TEXT not passed through: %v", args)
	}
}

func TestBuildXvncArgsAarch64LDPreload(t *testing.T) {
	const libgcc = "/lib/aarch64-linux-gnu/libgcc_s.so.1"
	cases := []struct {
		name        string
		arch        string
		exists      []string
		wantPreload bool
	}{
		{"arm64_with_libgcc", "arm64", []string{libgcc}, true},
		{"arm64_without_libgcc", "arm64", nil, false},
		{"amd64_never_preloads", "amd64", []string{libgcc}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, env, err := buildXvncArgs(map[string]string{}, tc.arch, fakeStat(tc.exists...), fakeHost)
			if err != nil {
				t.Fatal(err)
			}
			seen := false
			for _, e := range env {
				if strings.HasPrefix(e, "LD_PRELOAD=") && strings.Contains(e, libgcc) {
					seen = true
					break
				}
			}
			if seen != tc.wantPreload {
				t.Errorf("LD_PRELOAD seen = %v, want %v", seen, tc.wantPreload)
			}
		})
	}
}

func TestBuildXvncArgsDisplayNormalisation(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ":1"},
		{":1", ":1"},
		{":42", ":42"},
		{"7", ":7"},
	}
	for _, tc := range cases {
		args, _, err := buildXvncArgs(map[string]string{"DISPLAY": tc.in}, "amd64", fakeStat(), fakeHost)
		if err != nil {
			t.Fatal(err)
		}
		if args[1] != tc.want {
			t.Errorf("DISPLAY=%q -> %q, want %q", tc.in, args[1], tc.want)
		}
	}
}

func TestEnvMap(t *testing.T) {
	got := envMap([]string{"FOO=bar", "BAZ=", "=invalid", "KEY=val=with=equals"})
	if got["FOO"] != "bar" {
		t.Errorf("FOO = %q", got["FOO"])
	}
	if got["BAZ"] != "" {
		t.Errorf("BAZ should be empty string, got %q", got["BAZ"])
	}
	if _, ok := got[""]; ok {
		t.Errorf("empty key should be dropped")
	}
	if got["KEY"] != "val=with=equals" {
		t.Errorf("multi-equals split wrong: %q", got["KEY"])
	}
}
