// kasm-unpack-staticx installs a StaticX helper's bundled runtime once,
// at image build time, instead of on every container start.
//
// The Kasm Python helpers (gamepad, printer, smartcard, audio-input)
// ship as PyInstaller one-file executables wrapped by StaticX. At
// launch the StaticX bootloader decompresses a ~20 MiB xz tar into
// /tmp, patches the inner program's ELF interpreter and RPATH to point
// there, then execs it. This tool does that outer step ahead of time:
// the archive lands in /opt/kasm-unpacked/<name>/ and the original
// path becomes an `exec` wrapper. The inner PyInstaller archive is
// untouched and still extracts to /tmp/_MEI* at runtime.
//
// This is a Go port of upstream's src/ubuntu/install/tools/
// unpack_staticx.py (workspaces-core-images !420, VNC-574). The CLI
// name, arguments, on-disk layout and wrapper text are deliberately
// identical so the installer lines merge cleanly when that MR lands in
// develop. It is Go rather than Python because container-init images
// carry no Python, and it is a build-time tool only: cleanup.sh
// removes it from the final image.
package main

import (
	"archive/tar"
	"bytes"
	"debug/elf"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/xi2/xz"
)

const (
	archiveSection = ".staticx.archive"
	progLink       = ".staticx.prog"
	interpLink     = ".staticx.interp"
	// StaticX reserves fixed-width placeholders in the inner program:
	// 256 x 'i' for PT_INTERP and 256 x 'r' for DT_RPATH, each
	// NUL-terminated. Its bootloader overwrites them in place.
	placeholderLen = 256
)

// archiveBytes returns the raw .staticx.archive section of a StaticX
// executable. Only little-endian ELF64 is accepted: that is what the
// published amd64 and arm64 helpers are.
func archiveBytes(path string) ([]byte, error) {
	f, err := elf.Open(path)
	if err != nil {
		return nil, fmt.Errorf("expected a little-endian ELF64 StaticX executable: %w", err)
	}
	defer f.Close()
	if f.Class != elf.ELFCLASS64 || f.Data != elf.ELFDATA2LSB {
		return nil, errors.New("expected a little-endian ELF64 StaticX executable")
	}
	section := f.Section(archiveSection)
	if section == nil {
		return nil, errors.New("missing " + archiveSection + " section")
	}
	return section.Data()
}

type member struct {
	name     string
	linkname string // non-empty for symlinks
	mode     os.FileMode
	data     []byte
}

// decompress opens the archive's xz stream. StaticX compresses with a
// BCJ branch filter ahead of LZMA2 (BCJ-x86 on amd64), so the decoder
// must support multi-filter chains, not just bare LZMA2. An unknown
// filter fails here, and with it the image build.
func decompress(archive []byte) (io.Reader, error) {
	xr, err := xz.NewReader(bytes.NewReader(archive), 0)
	if err != nil {
		return nil, fmt.Errorf("unsupported StaticX archive compression: %w", err)
	}
	return xr, nil
}

// readBundle validates the tar stream fully before anything is written.
// StaticX archives are flat: regular files plus relative symlinks.
// Reject everything else rather than trusting tar paths, ownership or
// special files.
func readBundle(stream io.Reader) ([]member, error) {
	tr := tar.NewReader(stream)
	var members []member
	seen := map[string]bool{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		name := hdr.Name
		if name == "" || name == "." || name == ".." || strings.Contains(name, "/") || seen[name] {
			return nil, fmt.Errorf("unexpected archive path: %q", name)
		}
		seen[name] = true
		switch hdr.Typeflag {
		case tar.TypeReg:
			data, err := io.ReadAll(tr)
			if err != nil {
				return nil, err
			}
			mode := os.FileMode(0o644)
			if hdr.Mode&0o111 != 0 {
				mode = 0o755
			}
			members = append(members, member{name: name, mode: mode, data: data})
		case tar.TypeSymlink:
			link := hdr.Linkname
			if link == "" || link == "." || link == ".." || strings.Contains(link, "/") {
				return nil, fmt.Errorf("unexpected symlink: %q", name)
			}
			members = append(members, member{name: name, linkname: link})
		default:
			return nil, fmt.Errorf("unexpected archive entry: %q", name)
		}
	}
	return members, nil
}

func extractBundle(members []member, target string) error {
	for _, m := range members {
		path := filepath.Join(target, m.name)
		if m.linkname != "" {
			if err := os.Symlink(m.linkname, path); err != nil {
				return err
			}
			continue
		}
		if err := os.WriteFile(path, m.data, m.mode); err != nil {
			return err
		}
		// WriteFile's mode is subject to umask; the bundle must stay
		// readable by the unprivileged session user.
		if err := os.Chmod(path, m.mode); err != nil {
			return err
		}
	}
	return nil
}

// resolveInBundle follows one of StaticX's marker symlinks and insists
// the target is a regular file directly inside the bundle.
func resolveInBundle(staging, link string) (string, error) {
	resolved, err := filepath.EvalSymlinks(filepath.Join(staging, link))
	if err != nil {
		return "", errors.New("missing or invalid StaticX program/interpreter")
	}
	root, err := filepath.EvalSymlinks(staging)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil || filepath.Dir(resolved) != root || !info.Mode().IsRegular() {
		return "", errors.New("missing or invalid StaticX program/interpreter")
	}
	return resolved, nil
}

// patchPlaceholder overwrites a StaticX placeholder with value, padded
// with NULs to the original width so no ELF offsets move.
func patchPlaceholder(data []byte, fill byte, value string) ([]byte, error) {
	marker := append(bytes.Repeat([]byte{fill}, placeholderLen), 0)
	if len(value) > placeholderLen || bytes.Count(data, marker) != 1 {
		return nil, errors.New("unsupported StaticX interpreter/RPATH placeholder")
	}
	replacement := make([]byte, len(marker))
	copy(replacement, value)
	return bytes.Replace(data, marker, replacement, 1), nil
}

// shellQuote matches Python's shlex.quote, including leaving already
// safe strings bare, so the wrapper is byte-identical to upstream's.
func shellQuote(s string) string {
	safe := s != ""
	for _, r := range s {
		if !(r == '_' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
			strings.ContainsRune("@%+=:,./-", r)) {
			safe = false
			break
		}
	}
	if safe {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

func unpack(original, bundleRoot string) (err error) {
	if original, err = filepath.Abs(original); err != nil {
		return err
	}
	if bundleRoot, err = filepath.Abs(bundleRoot); err != nil {
		return err
	}
	destination := filepath.Join(bundleRoot, filepath.Base(original))
	if _, statErr := os.Lstat(destination); statErr == nil {
		return errors.New("bundle already installed: " + destination)
	}

	archive, err := archiveBytes(original)
	if err != nil {
		return err
	}
	stream, err := decompress(archive)
	if err != nil {
		return err
	}
	members, err := readBundle(stream)
	if err != nil {
		return err
	}

	if err = os.MkdirAll(bundleRoot, 0o755); err != nil {
		return err
	}
	staging, err := os.MkdirTemp(bundleRoot, ".unpack-")
	if err != nil {
		return err
	}
	// After the rename below this is a no-op; on any earlier failure it
	// leaves the bundle root as it was found.
	defer os.RemoveAll(staging)

	if err = extractBundle(members, staging); err != nil {
		return err
	}
	program, err := resolveInBundle(staging, progLink)
	if err != nil {
		return err
	}
	if _, err = resolveInBundle(staging, interpLink); err != nil {
		return err
	}

	data, err := os.ReadFile(program)
	if err != nil {
		return err
	}
	if data, err = patchPlaceholder(data, 'i', filepath.Join(destination, interpLink)); err != nil {
		return err
	}
	if data, err = patchPlaceholder(data, 'r', destination); err != nil {
		return err
	}
	if err = os.WriteFile(program, data, 0o755); err != nil {
		return err
	}
	if err = os.Chmod(staging, 0o755); err != nil {
		return err
	}
	if err = os.Rename(staging, destination); err != nil {
		return err
	}

	// exec keeps the supervisor's PID and signal handling on the helper
	// itself. The bundled libraries are found via the patched RPATH, so
	// LD_LIBRARY_PATH is not exported into unrelated system applications.
	wrapper := fmt.Sprintf("#!/bin/sh\nexport STATICX_BUNDLE_DIR=%s\nexport STATICX_PROG_PATH=%s\nexec %s \"$@\"\n",
		shellQuote(destination), shellQuote(original),
		shellQuote(filepath.Join(destination, filepath.Base(program))))
	if err = os.WriteFile(original, []byte(wrapper), 0o755); err != nil {
		return err
	}
	if err = os.Chmod(original, 0o755); err != nil {
		return err
	}
	fmt.Println("Installed private StaticX runtime: " + destination)
	return nil
}

func main() {
	bundleRoot := flag.String("bundle-root", "/opt/kasm-unpacked", "directory that receives <executable>/ bundles")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: %s [--bundle-root DIR] executable\n", os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	if err := unpack(flag.Arg(0), *bundleRoot); err != nil {
		fmt.Fprintf(os.Stderr, "Cannot unpack %s: %v\n", flag.Arg(0), err)
		os.Exit(1)
	}
}
