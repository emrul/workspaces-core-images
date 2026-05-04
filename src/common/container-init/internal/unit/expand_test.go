package unit

import "testing"

func TestExpand(t *testing.T) {
	env := map[string]string{
		"KASM_OS_USER": "alice",
		"EMPTY":        "",
		"VNC_PW":       "secret",
	}
	lookup := func(k string) (string, bool) {
		v, ok := env[k]
		return v, ok
	}
	cases := []struct {
		in, want string
	}{
		// Bare strings are unchanged.
		{"plain", "plain"},
		// Set var.
		{"User=${KASM_OS_USER}", "User=alice"},
		// Set var with default — set wins.
		{"User=${KASM_OS_USER:-kasm-user}", "User=alice"},
		// Unset var with default — default wins.
		{"Group=${KASM_OS_GROUP:-kasm-user}", "Group=kasm-user"},
		// Unset var, no default — empty.
		{"Home=${KASM_OS_HOME}", "Home="},
		// Empty-string env counts as unset for ${VAR:-default}.
		{"Val=${EMPTY:-fallback}", "Val=fallback"},
		// Empty default is allowed.
		{"Val=${KASM_OS_GROUP:-}", "Val="},
		// Bare $VAR is not recognised — '$' passes through.
		{"X=$KASM_OS_USER", "X=$KASM_OS_USER"},
		// Literal $$ collapses to $.
		{"sum=$$1", "sum=$1"},
		// Two refs in the same value.
		{"a=${KASM_OS_USER}/${KASM_OS_HOME:-/home/kasm-user}", "a=alice//home/kasm-user"},
		// Unterminated ${ — pass through verbatim.
		{"oops=${KASM_OS_USER", "oops=${KASM_OS_USER"},
		// Nested ${...} inside a default — VNC_PW set, expands.
		{"auth=${KASM_AUDIO_AUTH:-kasm_user:${VNC_PW}}", "auth=kasm_user:secret"},
		// Nested ${...:-...} inside a default with both unset — empty fallback chain.
		{"auth=${KASM_AUDIO_AUTH:-kasm_user:${MISSING:-fallback}}", "auth=kasm_user:fallback"},
		// Nested unset, no default → empty in the middle.
		{"auth=${KASM_AUDIO_AUTH:-kasm_user:${MISSING}}", "auth=kasm_user:"},
		// Outer var set — default (with nested ref) is ignored entirely.
		{"auth=${KASM_OS_USER:-other:${VNC_PW}}", "auth=alice"},
		// Two nested refs in one default.
		{"x=${UNSET:-${KASM_OS_USER}/${VNC_PW}}", "x=alice/secret"},
	}
	for _, c := range cases {
		got := Expand(c.in, lookup)
		if got != c.want {
			t.Errorf("Expand(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
