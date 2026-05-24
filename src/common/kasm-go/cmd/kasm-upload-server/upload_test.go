package main

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// TestEndToEnd exercises the same wire contract the parity_test/
// shell harness asserts against the Python helper, but as a self-
// contained Go test so CI catches regressions before the slow
// container-based parity run.
func TestEndToEnd(t *testing.T) {
	uploadDir := t.TempDir()
	const token = "kasm_user:secret"
	srv := httptest.NewTLSServer(buildHandler(uploadDir, token, &activity{}))
	defer srv.Close()

	client := srv.Client()
	client.Transport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}

	type fields struct {
		idx, off, total, count string
		filename               string
		body                   []byte
		auth                   string // "" = none, "basic:user:pw", "raw:<header>"
	}

	post := func(t *testing.T, f fields) (*http.Response, []byte) {
		t.Helper()
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		writeIfSet := func(k, v string) {
			if v != "" {
				_ = mw.WriteField(k, v)
			}
		}
		writeIfSet("dzchunkindex", f.idx)
		writeIfSet("dzchunkbyteoffset", f.off)
		writeIfSet("dztotalfilesize", f.total)
		writeIfSet("dztotalchunkcount", f.count)
		if f.filename != "" {
			fw, err := mw.CreateFormFile("file", f.filename)
			if err != nil {
				t.Fatalf("CreateFormFile: %v", err)
			}
			_, _ = fw.Write(f.body)
		}
		_ = mw.Close()

		req, _ := http.NewRequest("POST", srv.URL+"/upload", &buf)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		switch {
		case f.auth == "":
			// no header
		case strings.HasPrefix(f.auth, "basic:"):
			creds := strings.TrimPrefix(f.auth, "basic:")
			req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(creds)))
		case strings.HasPrefix(f.auth, "raw:"):
			req.Header.Set("Authorization", strings.TrimPrefix(f.auth, "raw:"))
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("client.Do: %v", err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, body
	}

	t.Run("missing auth -> 403 + AuthMissing body", func(t *testing.T) {
		resp, body := post(t, fields{idx: "0", off: "0", total: "5", count: "1", filename: "x.txt", body: []byte("hello")})
		mustStatus(t, resp, 403)
		mustBody(t, body, bodyAuthMissing)
		mustHeader(t, resp, "Content-Type", contentTypeHTML)
	})

	t.Run("bearer auth -> 403 + AuthMissing body", func(t *testing.T) {
		resp, body := post(t, fields{
			idx: "0", off: "0", total: "5", count: "1", filename: "x.txt", body: []byte("hello"),
			auth: "raw:Bearer abc",
		})
		mustStatus(t, resp, 403)
		mustBody(t, body, bodyAuthMissing)
	})

	t.Run("wrong creds -> 403 + AccessDenied body", func(t *testing.T) {
		resp, body := post(t, fields{
			idx: "0", off: "0", total: "5", count: "1", filename: "x.txt", body: []byte("hello"),
			auth: "basic:kasm_user:wrong",
		})
		mustStatus(t, resp, 403)
		mustBody(t, body, bodyAccessDenied)
	})

	t.Run("missing dzchunkindex -> 400", func(t *testing.T) {
		resp, _ := post(t, fields{off: "0", total: "5", count: "1", filename: "x.txt", body: []byte("hello"), auth: "basic:" + token})
		mustStatus(t, resp, 400)
	})

	t.Run("happy path single chunk -> 200 + uploaded Chunk", func(t *testing.T) {
		payload := []byte("hello-from-go-test\n")
		resp, body := post(t, fields{
			idx: "0", off: "0", total: fmt.Sprintf("%d", len(payload)), count: "1",
			filename: "single.txt", body: payload,
			auth:     "basic:" + token,
		})
		mustStatus(t, resp, 200)
		mustBody(t, body, bodyOK)
		mustHeader(t, resp, "Content-Type", contentTypeHTML)
		got, err := os.ReadFile(filepath.Join(uploadDir, "single.txt"))
		if err != nil {
			t.Fatalf("read uploaded: %v", err)
		}
		if !bytes.Equal(got, payload) {
			t.Fatalf("disk bytes mismatch: got %q want %q", got, payload)
		}
		st, _ := os.Stat(filepath.Join(uploadDir, "single.txt"))
		if mode := st.Mode().Perm(); mode != 0o644 {
			t.Errorf("file mode %o, want 644", mode)
		}
	})

	t.Run("re-upload same name -> 400 + File already exists", func(t *testing.T) {
		resp, body := post(t, fields{
			idx: "0", off: "0", total: "1", count: "1",
			filename: "single.txt", body: []byte("x"),
			auth:     "basic:" + token,
		})
		mustStatus(t, resp, 400)
		mustBody(t, body, bodyFileExists)
	})

	t.Run("two chunks reassemble at correct offsets", func(t *testing.T) {
		c0 := bytes.Repeat([]byte("A"), 50)
		c1 := bytes.Repeat([]byte("B"), 50)
		resp, body := post(t, fields{
			idx: "0", off: "0", total: "100", count: "2",
			filename: "two.bin", body: c0,
			auth:     "basic:" + token,
		})
		mustStatus(t, resp, 200)
		mustBody(t, body, bodyOK)
		// Intermediate: staging file present, final absent
		if _, err := os.Stat(filepath.Join(uploadDir, "two.bin")); !os.IsNotExist(err) {
			t.Errorf("intermediate chunk: final file should not exist yet")
		}
		if _, err := os.Stat(filepath.Join(uploadDir, ".two.bin.uploading")); err != nil {
			t.Errorf("intermediate chunk: staging file missing: %v", err)
		}
		// Final chunk
		resp, body = post(t, fields{
			idx: "1", off: "50", total: "100", count: "2",
			filename: "two.bin", body: c1,
			auth:     "basic:" + token,
		})
		mustStatus(t, resp, 200)
		mustBody(t, body, bodyOK)
		got, err := os.ReadFile(filepath.Join(uploadDir, "two.bin"))
		if err != nil {
			t.Fatalf("read two.bin: %v", err)
		}
		want := append(c0, c1...)
		if !bytes.Equal(got, want) {
			t.Fatalf("two-chunk reassembly mismatch")
		}
		if _, err := os.Stat(filepath.Join(uploadDir, ".two.bin.uploading")); !os.IsNotExist(err) {
			t.Errorf("final chunk: staging file should be renamed away")
		}
	})

	t.Run("GET /upload -> 405", func(t *testing.T) {
		resp, _ := client.Get(srv.URL + "/upload")
		mustStatus(t, resp, 405)
		resp.Body.Close()
	})

	t.Run("GET / -> 404", func(t *testing.T) {
		resp, _ := client.Get(srv.URL + "/")
		mustStatus(t, resp, 404)
		resp.Body.Close()
	})
}

func TestSanitizeFilename(t *testing.T) {
	cases := map[string]string{
		"plain.txt":            "plain.txt",
		"../escape.txt":        "..escape.txt",
		"/abs/path.txt":        "abspath.txt",
		"a\\b\\c.txt":          "abc.txt",
		"":                     "",
		"...":                  "...",
		"weird:name?.txt":      "weird:name?.txt",
	}
	for in, want := range cases {
		if got := sanitizeFilename(in); got != want {
			t.Errorf("sanitizeFilename(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTranslateBoolArg(t *testing.T) {
	in := []string{"--ssl", "--debug", "true", "--port", "4902"}
	got := translateBoolArg(in, "--debug")
	want := []string{"--ssl", "--debug=true", "--port", "4902"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("translateBoolArg = %v, want %v", got, want)
	}
	// Untouched when the next arg isn't a bool literal.
	in = []string{"--debug", "--ssl"}
	got = translateBoolArg(in, "--debug")
	if strings.Join(got, " ") != strings.Join(in, " ") {
		t.Errorf("translateBoolArg leaked a rewrite: %v", got)
	}
}

func TestActivityCounter(t *testing.T) {
	a := &activity{}
	if a.snapshot() != 0 {
		t.Fatalf("initial snapshot != 0")
	}
	const N = 1000
	var wg int32
	for i := 0; i < N; i++ {
		go func() {
			a.tick()
			atomic.AddInt32(&wg, 1)
		}()
	}
	for atomic.LoadInt32(&wg) < N {
	}
	if got := a.snapshot(); got != N {
		t.Errorf("snapshot after %d ticks = %d", N, got)
	}
}

// TestNativeSocketActivation simulates the sd_listen_fds protocol
// inside the test process. We bind a TCP listener, pass it as fd 3,
// set LISTEN_FDS=1 and LISTEN_PID=getpid(), call acquireListener,
// and assert it returns the same listener (not a fresh bind).
func TestNativeSocketActivation(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("seed listen: %v", err)
	}
	defer ln.Close()
	tcpLn := ln.(*net.TCPListener)
	f, err := tcpLn.File()
	if err != nil {
		t.Fatalf("File(): %v", err)
	}
	defer f.Close()

	// `go test` keeps a fd open at fd 3 (the test binary's log).
	// Save + restore so we don't break the runtime, then dup our
	// listener fd onto fd 3 for the duration of the test.
	target := 3
	saved := fdSave(target)
	t.Cleanup(func() { fdRestore(target, saved) })
	if err := dupTo(f, target); err != nil {
		t.Skipf("can't dup to fd 3 in this environment: %v", err)
	}
	t.Setenv("LISTEN_FDS", "1")
	t.Setenv("LISTEN_PID", fmt.Sprintf("%d", os.Getpid()))

	got, source, err := acquireListener("127.0.0.1:0")
	if err != nil {
		t.Fatalf("acquireListener: %v", err)
	}
	defer got.Close()
	if source != "sd_listen_fds" {
		t.Errorf("source = %q, want sd_listen_fds", source)
	}
	// Round-trip: dial the address the *seed* listener was bound to;
	// the inherited listener should accept on it.
	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := got.Accept()
		ch <- accepted{c, err}
	}()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	a := <-ch
	if a.err != nil {
		t.Fatalf("accept: %v", a.err)
	}
	a.c.Close()
}
