package main

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type entry struct {
	name     string
	typeflag byte
	linkname string
	data     string
}

// bundle builds an uncompressed tar stream: member validation is
// independent of the xz layer, which TestDecompressBCJChain covers.
func bundle(t *testing.T, entries ...entry) *bytes.Reader {
	t.Helper()
	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	for _, e := range entries {
		hdr := &tar.Header{Name: e.name, Typeflag: e.typeflag, Linkname: e.linkname, Mode: 0o755, Size: int64(len(e.data))}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(out.Bytes())
}

// Real StaticX archives are BCJ-x86 + LZMA2, not bare LZMA2. A decoder
// limited to single-filter streams passes synthetic tests and then
// fails on every published helper, so pin the real chain with a fixture
// (python: lzma.compress(filters=[FILTER_X86, FILTER_LZMA2])).
func TestDecompressBCJChain(t *testing.T) {
	archive, err := os.ReadFile(filepath.Join("testdata", "bcj-x86.tar.xz"))
	if err != nil {
		t.Fatal(err)
	}
	stream, err := decompress(archive)
	if err != nil {
		t.Fatal(err)
	}
	members, err := readBundle(stream)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 || members[0].name != "helper" || members[1].linkname != "helper" {
		t.Fatalf("unexpected members: %+v", members)
	}
}

func TestDecompressRejectsNonXZ(t *testing.T) {
	stream, err := decompress([]byte("not an xz stream"))
	if err == nil {
		_, err = readBundle(stream)
	}
	if err == nil {
		t.Fatal("accepted")
	}
}

func TestReadBundleAcceptsFlatFilesAndRelativeSymlinks(t *testing.T) {
	members, err := readBundle(bundle(t,
		entry{name: "helper", typeflag: tar.TypeReg, data: "prog"},
		entry{name: progLink, typeflag: tar.TypeSymlink, linkname: "helper"},
	))
	if err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	if err := extractBundle(members, target); err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveInBundle(target, progLink)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(resolved) != "helper" {
		t.Fatalf("resolved %q", resolved)
	}
}

// Nothing may be written when any member is unsafe: validation happens
// before extraction, so a hostile archive cannot leave partial output.
func TestReadBundleRejectsUnsafeMembers(t *testing.T) {
	cases := map[string]entry{
		"nested path":      {name: "lib/evil", typeflag: tar.TypeReg},
		"parent path":      {name: "..", typeflag: tar.TypeReg},
		"absolute path":    {name: "/etc/passwd", typeflag: tar.TypeReg},
		"escaping symlink": {name: "link", typeflag: tar.TypeSymlink, linkname: "../outside"},
		"absolute symlink": {name: "link", typeflag: tar.TypeSymlink, linkname: "/etc/passwd"},
		"hard link":        {name: "link", typeflag: tar.TypeLink, linkname: "helper"},
		"device":           {name: "dev", typeflag: tar.TypeChar},
		"directory":        {name: "dir", typeflag: tar.TypeDir},
	}
	for label, bad := range cases {
		t.Run(label, func(t *testing.T) {
			_, err := readBundle(bundle(t, entry{name: "helper", typeflag: tar.TypeReg, data: "x"}, bad))
			if err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

func TestReadBundleRejectsDuplicateNames(t *testing.T) {
	_, err := readBundle(bundle(t,
		entry{name: "helper", typeflag: tar.TypeReg, data: "a"},
		entry{name: "helper", typeflag: tar.TypeReg, data: "b"},
	))
	if err == nil {
		t.Fatal("accepted")
	}
}

func TestPatchPlaceholderKeepsLength(t *testing.T) {
	marker := strings.Repeat("i", placeholderLen) + "\x00"
	data := []byte("head" + marker + "tail")
	patched, err := patchPlaceholder(data, 'i', "/opt/kasm-unpacked/helper/.staticx.interp")
	if err != nil {
		t.Fatal(err)
	}
	if len(patched) != len(data) {
		t.Fatalf("length moved: %d -> %d", len(data), len(patched))
	}
	want := "head/opt/kasm-unpacked/helper/.staticx.interp\x00"
	if !bytes.HasPrefix(patched, []byte(want)) || !bytes.HasSuffix(patched, []byte("\x00tail")) {
		t.Fatalf("unexpected patch result")
	}
}

func TestPatchPlaceholderRejectsMissingDuplicateOrOverlong(t *testing.T) {
	marker := strings.Repeat("r", placeholderLen) + "\x00"
	if _, err := patchPlaceholder([]byte("none"), 'r', "/x"); err == nil {
		t.Fatal("missing placeholder accepted")
	}
	if _, err := patchPlaceholder([]byte(marker+marker), 'r', "/x"); err == nil {
		t.Fatal("duplicate placeholder accepted")
	}
	if _, err := patchPlaceholder([]byte(marker), 'r', "/"+strings.Repeat("p", placeholderLen)); err == nil {
		t.Fatal("overlong value accepted")
	}
}

func TestInvalidInputPreservesOriginal(t *testing.T) {
	dir := t.TempDir()
	original := filepath.Join(dir, "helper")
	content := []byte("not a StaticX executable")
	if err := os.WriteFile(original, content, 0o755); err != nil {
		t.Fatal(err)
	}
	bundles := filepath.Join(dir, "bundles")
	if err := unpack(original, bundles); err == nil {
		t.Fatal("accepted")
	}
	got, _ := os.ReadFile(original)
	if !bytes.Equal(got, content) {
		t.Fatal("original was modified")
	}
	if _, err := os.Stat(bundles); !os.IsNotExist(err) {
		t.Fatal("bundle root was created")
	}
}

func TestShellQuote(t *testing.T) {
	for in, want := range map[string]string{
		"/opt/kasm-unpacked/helper": "/opt/kasm-unpacked/helper",
		"/opt/it's":                 `'/opt/it'"'"'s'`,
		"/opt/with space":           "'/opt/with space'",
		"":                          "''",
	} {
		if got := shellQuote(in); got != want {
			t.Fatalf("shellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}
