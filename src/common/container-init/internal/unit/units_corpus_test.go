package unit

import (
	"path/filepath"
	"sort"
	"testing"
)

// TestProductionUnitsParseClean is the 4.6 hand-off check: the full
// Kasm unit set under units/ must parse with zero warnings against
// the documented directive subset and pass cross-directive validation
// (no missing ExecStart, ListenStream + Service consistency, etc.).
func TestProductionUnitsParseClean(t *testing.T) {
	dir := filepath.Join("..", "..", "units")
	units, warnings, err := LoadDir(dir, Options{Lookup: func(string) (string, bool) { return "", false }})
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(warnings) != 0 {
		for _, w := range warnings {
			t.Errorf("warning: %s", w)
		}
		t.Fatalf("%d warning(s); want 0", len(warnings))
	}

	want := []string{
		"audio-in.service",
		"audio-in.socket",
		"audio-out-ws.service",
		"audio-out-ws.socket",
		"audio-out.service",
		"custom-startup.service",
		"gamepad.service",
		"gamepad.socket",
		"kasm-setup.service",
		"kasmvnc.service",
		"network-wait.service",
		"pcscd.service",
		"printer.service",
		"profile-pull.service",
		"profile-size-check.service",
		"recorder-drain.service",
		"recorder-watch.service",
		"smartcard.service",
		"upload.service",
		"upload.socket",
		"webcam.service",
		"webcam.socket",
		"window-manager.service",
	}
	got := make([]string, 0, len(units))
	for _, u := range units {
		got = append(got, u.Name)
	}
	sort.Strings(got)
	if len(got) != len(want) {
		t.Errorf("loaded %d units, want %d (got=%v)", len(got), len(want), got)
	}
	for i, n := range want {
		if i >= len(got) || got[i] != n {
			t.Errorf("unit[%d] = %q, want %q", i, get(got, i), n)
		}
	}

	// Spot-check the cross-cutting properties the brief calls out.
	by := byNameMap(units)
	if u := by["kasmvnc.service"]; u == nil || u.User != "kasm-user" {
		t.Errorf("kasmvnc.service User= didn't expand to kasm-user; got %#v", u)
	}
	if u := by["window-manager.service"]; u == nil || len(u.OnFailure) == 0 || u.OnFailure[0] != "recorder-drain.service" {
		t.Errorf("window-manager.service OnFailure missing recorder-drain.service")
	}
	if u := by["upload.socket"]; u == nil || u.ActivationMode != ActivationNative {
		t.Errorf("upload.socket should be native mode")
	}
	for _, name := range []string{"audio-out-ws.socket", "audio-in.socket", "gamepad.socket", "webcam.socket"} {
		u := by[name]
		if u == nil {
			t.Errorf("%s missing", name)
			continue
		}
		if u.ActivationMode != ActivationProxy {
			t.Errorf("%s should be proxy mode, got %v", name, u.ActivationMode)
		}
		if u.ProxyTarget == "" {
			t.Errorf("%s missing ProxyTarget=", name)
		}
	}
	if u := by["recorder-drain.service"]; u == nil || !u.ExitContainerOnFailure {
		t.Errorf("recorder-drain.service must have ExitContainerOnFailure=true")
	}
	// Both kill switches present.
	for _, name := range []string{"kasmvnc.service", "audio-out-ws.socket", "upload.socket"} {
		u := by[name]
		if u == nil {
			continue
		}
		hasVnc := false
		for _, c := range u.ConditionEnvironment {
			if c == "KASM_VNC=1" {
				hasVnc = true
			}
		}
		if !hasVnc {
			t.Errorf("%s missing ConditionEnvironment=KASM_VNC=1", name)
		}
	}
	if u := by["profile-pull.service"]; u != nil {
		hasPull := false
		for _, c := range u.ConditionEnvironment {
			if c == "KASM_PROFILE_PULL=1" {
				hasPull = true
			}
		}
		if !hasPull {
			t.Errorf("profile-pull.service missing ConditionEnvironment=KASM_PROFILE_PULL=1")
		}
	}
}

func byNameMap(units []*Unit) map[string]*Unit {
	out := make(map[string]*Unit, len(units))
	for _, u := range units {
		out[u.Name] = u
	}
	return out
}

func get(s []string, i int) string {
	if i < 0 || i >= len(s) {
		return "<missing>"
	}
	return s[i]
}
