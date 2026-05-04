package main

import (
	"reflect"
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

func TestBuildXvncArgsKasmDefaults(t *testing.T) {
	env := map[string]string{
		"DISPLAY":         ":1",
		"DRINODE":         "/dev/dri/renderD128",
		"VNC_COL_DEPTH":   "24",
		"VNC_RESOLUTION":  "1280x800",
		"NO_VNC_PORT":     "6901",
		"KASM_VNC_PATH":   "/usr/share/kasmvnc",
		"MAX_FRAME_RATE":  "24",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat())
	if err != nil {
		t.Fatalf("buildXvncArgs: %v", err)
	}
	want := []string{
		"/usr/bin/Xvnc", ":1",
		"-drinode", "/dev/dri/renderD128",
		"-depth", "24",
		"-geometry", "1280x800",
		"-websocketPort", "6901",
		"-httpd", "/usr/share/kasmvnc/www",
		"-sslOnly",
		"-interface", "0.0.0.0",
		"-BlacklistThreshold=0",
		"-FreeKeyMappings",
		"-FrameRate=24",
		// Default-on toggles for printer + smartcard.
		"-UnixRelay", "printer:/tmp/printer",
		"-UnixRelay", "smartcard:/tmp/smartcard",
	}
	if !reflect.DeepEqual(args, want) {
		t.Errorf("\n got: %v\nwant: %v", args, want)
	}
}

func TestBuildXvncArgsToggleSuppress(t *testing.T) {
	env := map[string]string{
		"DISPLAY":           ":1",
		"VNC_RESOLUTION":    "1024x768",
		"KASM_SVC_PRINTER":  "0",
		"KASM_SVC_SMARTCARD": "false",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat())
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range args {
		if strings.Contains(a, "/tmp/printer") || strings.Contains(a, "/tmp/smartcard") {
			t.Errorf("UnixRelay flag leaked when toggle suppressed: %v", args)
		}
	}
}

func TestBuildXvncArgsHW3DAndExtras(t *testing.T) {
	env := map[string]string{
		"DISPLAY":               ":1",
		"HW3D":                  "1",
		"VNCOPTIONS":            "-Log *:stderr:30 -DLP_Region_Allow_List=*",
		"KASM_SVC_SEND_CUT_TEXT": "-acceptCutText -setPrimary",
	}
	args, _, err := buildXvncArgs(env, "amd64", fakeStat())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-hw3d") {
		t.Errorf("HW3D=1 should produce -hw3d: %v", args)
	}
	if !strings.Contains(joined, "-Log *:stderr:30") {
		t.Errorf("VNCOPTIONS not pass-through: %v", args)
	}
	if !strings.Contains(joined, "-acceptCutText") || !strings.Contains(joined, "-setPrimary") {
		t.Errorf("KASM_SVC_SEND_CUT_TEXT tokens lost: %v", args)
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
			_, env, err := buildXvncArgs(map[string]string{"DISPLAY": ":1"}, tc.arch, fakeStat(tc.exists...))
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
				t.Errorf("LD_PRELOAD seen = %v, want %v (env=%v)", seen, tc.wantPreload, env)
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
		args, _, err := buildXvncArgs(map[string]string{"DISPLAY": tc.in}, "amd64", fakeStat())
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
