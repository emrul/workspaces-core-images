// kasm-upload-server is the Go drop-in replacement for the
// PyInstaller-bundled Flask helper at
// /dockerstartup/upload_server/kasm_upload_server. The wire contract,
// argv, env-var protocol, multipart fields, file-staging algorithm,
// and response bodies match the Python helper byte-for-byte so that
// the noVNC client (and anything else hitting POST /upload) cannot
// observe the swap.
//
// Wire contract reverse-engineered against
// docker.io/kasmweb/core-ubuntu-noble:1.18.0-rolling-daily during
// Phase 3 prep — see design/work_sequence.md § Phase 3 and the
// parity_test/ harness for the spec the binary is held to.
//
// Native socket activation is supported via LISTEN_PID/LISTEN_FDS
// (sd_listen_fds protocol, fd 3). When neither is set the helper
// falls back to binding --listen / --port directly so the bash path's
// existing exec line continues to work unchanged.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	bodyAuthMissing  = "Authorization Header missing or invalid"
	bodyAccessDenied = "Access Denied!"
	bodyFileExists   = "File already exists"
	bodyOK           = "uploaded Chunk"
	contentTypeHTML  = "text/html; charset=utf-8"
)

func main() {
	var (
		ssl         bool
		port        int
		listenAddr  string
		uploadDir   string
		authToken   string
		certPath    string
		keyPath     string
		idleTimeout time.Duration
		debug       bool
	)

	fs := flag.NewFlagSet("kasm-upload-server", flag.ContinueOnError)
	fs.BoolVar(&ssl, "ssl", false, "serve TLS")
	fs.IntVar(&port, "port", 4902, "listening port (ignored when LISTEN_FDS is set)")
	fs.StringVar(&listenAddr, "listen", "", "listen address override (host:port); defaults to 0.0.0.0:--port")
	fs.StringVar(&uploadDir, "upload-dir", "", "directory to receive uploads")
	fs.StringVar(&uploadDir, "upload_dir", "", "alias for --upload-dir (Python argparse compatibility)")
	fs.StringVar(&authToken, "auth-token", "", "user:password Basic credential")
	fs.StringVar(&certPath, "cert", "", "TLS cert file (PEM); when unset, an ephemeral self-signed cert is used")
	fs.StringVar(&keyPath, "key", "", "TLS key file (PEM); when unset, paired with --cert (combined PEM ok)")
	fs.DurationVar(&idleTimeout, "idle-timeout", 0, "exit cleanly after this much idle time (default: never)")
	// --debug is accepted for argparse compatibility (`--debug true`),
	// but the Python helper's debug mode (Werkzeug reloader + debugger)
	// is deliberately not reproduced.
	fs.BoolVar(&debug, "debug", false, "ignored; accepted for compatibility")
	// Argparse accepts `--debug true`; flag.BoolVar requires `=true`.
	// Translate the bare positional form before parsing.
	if err := fs.Parse(translateBoolArg(os.Args[1:], "--debug")); err != nil {
		log.Fatalf("flag parse: %v", err)
	}

	log.SetFlags(log.LstdFlags)
	log.SetPrefix("kasm-upload-server: ")

	if uploadDir == "" {
		log.Fatalf("--upload-dir is required")
	}
	if authToken == "" {
		log.Fatalf("--auth-token is required")
	}
	if err := os.MkdirAll(uploadDir, 0o755); err != nil {
		log.Fatalf("upload dir %s: %v", uploadDir, err)
	}

	if listenAddr == "" {
		listenAddr = fmt.Sprintf("0.0.0.0:%d", port)
	}

	ln, source, err := acquireListener(listenAddr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("listening on %s (%s)", ln.Addr(), source)

	srv := &http.Server{
		ReadHeaderTimeout: 30 * time.Second,
		// Force HTTP/1.1 — the Python helper is Werkzeug-on-h11. Go's
		// default would negotiate h2 over ALPN and the response
		// start-line would diverge from the Python wire bytes. The
		// noVNC client speaks both, but parity is the contract.
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
	}

	if ssl {
		cfg, err := tlsConfig(certPath, keyPath)
		if err != nil {
			log.Fatalf("tls: %v", err)
		}
		srv.TLSConfig = cfg
	}

	act := &activity{}
	srv.Handler = buildHandler(uploadDir, authToken, act)

	idleCancel := func() {}
	if idleTimeout > 0 {
		var ctx context.Context
		ctx, idleCancel = context.WithCancel(context.Background())
		go watchIdle(ctx, srv, act, idleTimeout)
	}

	serveErr := make(chan error, 1)
	go func() {
		if ssl {
			serveErr <- srv.ServeTLS(ln, "", "")
		} else {
			serveErr <- srv.Serve(ln)
		}
	}()

	if err := <-serveErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		idleCancel()
		log.Fatalf("serve: %v", err)
	}
	idleCancel()
}

// translateBoolArg rewrites `<flag> true|false|1|0` into `<flag>=true|false`
// so Go's flag package accepts argparse-style positional bool values.
// Anything else is left untouched.
func translateBoolArg(args []string, name string) []string {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == name && i+1 < len(args) {
			switch strings.ToLower(args[i+1]) {
			case "true", "1", "yes":
				out = append(out, name+"=true")
				i++
				continue
			case "false", "0", "no":
				out = append(out, name+"=false")
				i++
				continue
			}
		}
		out = append(out, args[i])
	}
	return out
}

// acquireListener returns a listener from sd_listen_fds (fd 3) when
// LISTEN_FDS is set and LISTEN_PID matches; otherwise it binds addr
// directly. Both paths return TCP listeners — kasm-upload-server is
// HTTP/HTTPS only.
func acquireListener(addr string) (net.Listener, string, error) {
	if nfds := getEnvInt("LISTEN_FDS", 0); nfds > 0 {
		if pid := getEnvInt("LISTEN_PID", 0); pid != 0 && pid != os.Getpid() {
			return nil, "", fmt.Errorf("LISTEN_PID=%d != getpid()=%d", pid, os.Getpid())
		}
		if nfds != 1 {
			return nil, "", fmt.Errorf("LISTEN_FDS=%d, expected exactly 1", nfds)
		}
		f := os.NewFile(3, "listener")
		if f == nil {
			return nil, "", fmt.Errorf("fd 3 is not a valid file")
		}
		ln, err := net.FileListener(f)
		if err != nil {
			return nil, "", fmt.Errorf("FileListener(fd 3): %w", err)
		}
		// net.FileListener dup'd the fd; release our copy.
		_ = f.Close()
		return ln, "sd_listen_fds", nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", err
	}
	return ln, "bind", nil
}

// tlsConfig returns a TLS config: real cert when paths are given,
// otherwise an in-memory ephemeral self-signed cert that mirrors what
// Werkzeug's `ssl_context='adhoc'` produces in the Python helper.
func tlsConfig(certPath, keyPath string) (*tls.Config, error) {
	if certPath != "" {
		kp := keyPath
		if kp == "" {
			kp = certPath // combined PEM (key + cert) — same shape as ~/.vnc/self.pem
		}
		cert, err := tls.LoadX509KeyPair(certPath, kp)
		if err != nil {
			return nil, fmt.Errorf("load cert %s/%s: %w", certPath, kp, err)
		}
		return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, nil
	}
	cert, err := generateAdhocCert()
	if err != nil {
		return nil, fmt.Errorf("generate adhoc cert: %w", err)
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, nil
}

// generateAdhocCert creates an ephemeral self-signed P-256 cert valid
// for 24 hours. P-256 keygen is ~1 ms vs 80-250 ms for RSA-2048
// (cold-start budget for this binary is ≤20 ms — see
// design/work_sequence.md Phase 3 completion criteria). The noVNC
// client doesn't validate the cert, matching Werkzeug's adhoc
// behaviour.
func generateAdhocCert() (tls.Certificate, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "kasm-upload-server"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return tls.X509KeyPair(certPEM, keyPEM)
}

// activity counts requests; the idle watcher samples it.
type activity struct {
	count atomic.Uint64
}

func (a *activity) tick()         { a.count.Add(1) }
func (a *activity) snapshot() uint64 { return a.count.Load() }

func buildHandler(uploadDir, authToken string, act *activity) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/upload", func(w http.ResponseWriter, r *http.Request) {
		act.tick()
		if r.Method != http.MethodPost {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		handleUpload(w, r, uploadDir, authToken)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		act.tick()
		http.NotFound(w, r)
	})
	return mux
}

// handleUpload implements POST /upload. Order of checks matches the
// Python helper exactly so failure modes are observable in the same
// sequence.
func handleUpload(w http.ResponseWriter, r *http.Request, uploadDir, authToken string) {
	if !checkAuth(r, authToken, w) {
		return
	}

	// Parse multipart with a generous in-memory threshold; chunks
	// stream through file backing past 32 MiB.
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeText(w, http.StatusBadRequest, "bad multipart: "+err.Error())
		return
	}

	form := r.MultipartForm
	if form == nil {
		writeText(w, http.StatusBadRequest, "missing multipart form")
		return
	}

	// All four are required; missing one is a Bad Request (Python
	// raises BadRequestKeyError → 400 in production).
	chunkIndex, ok := requireIntField(form.Value, "dzchunkindex", w)
	if !ok {
		return
	}
	chunkOffset, ok := requireIntField(form.Value, "dzchunkbyteoffset", w)
	if !ok {
		return
	}
	totalSize, ok := requireIntField(form.Value, "dztotalfilesize", w)
	if !ok {
		return
	}
	totalChunks, ok := requireIntField(form.Value, "dztotalchunkcount", w)
	if !ok {
		return
	}
	_ = totalSize // accepted for parity; not consumed for finalisation

	files := form.File["file"]
	if len(files) == 0 {
		writeText(w, http.StatusBadRequest, "missing 'file' part")
		return
	}
	fh := files[0]

	safeName := sanitizeFilename(fh.Filename)
	finalPath := filepath.Join(uploadDir, safeName)
	stagingPath := filepath.Join(uploadDir, "."+safeName+".uploading")

	// Existence check matches Python helper: refuse to overwrite the
	// already-completed final file. Returns 400 + "File already exists".
	if _, err := os.Stat(finalPath); err == nil {
		writeText(w, http.StatusBadRequest, bodyFileExists)
		return
	} else if !errors.Is(err, os.ErrNotExist) {
		writeText(w, http.StatusInternalServerError, "stat: "+err.Error())
		return
	}

	src, err := fh.Open()
	if err != nil {
		writeText(w, http.StatusInternalServerError, "open part: "+err.Error())
		return
	}
	defer src.Close()

	dst, err := os.OpenFile(stagingPath, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		writeText(w, http.StatusInternalServerError, "open staging: "+err.Error())
		return
	}
	if _, err := dst.Seek(int64(chunkOffset), io.SeekStart); err != nil {
		dst.Close()
		writeText(w, http.StatusInternalServerError, "seek: "+err.Error())
		return
	}
	if _, err := io.Copy(dst, src); err != nil {
		dst.Close()
		writeText(w, http.StatusInternalServerError, "write: "+err.Error())
		return
	}
	if err := dst.Close(); err != nil {
		writeText(w, http.StatusInternalServerError, "close: "+err.Error())
		return
	}

	// Last chunk → atomic rename to final filename. The Python helper
	// uses index+1==count as the trigger; chunksize is not consulted.
	if chunkIndex+1 >= totalChunks {
		if err := os.Rename(stagingPath, finalPath); err != nil {
			writeText(w, http.StatusInternalServerError, "rename: "+err.Error())
			return
		}
	}

	writeText(w, http.StatusOK, bodyOK)
}

// checkAuth replicates the Python helper's two-tier failure mode:
//   - missing or non-Basic Authorization → 403 + "Authorization Header missing or invalid"
//   - Basic header present but credentials wrong → 403 + "Access Denied!"
func checkAuth(r *http.Request, expected string, w http.ResponseWriter) bool {
	hdr := r.Header.Get("Authorization")
	if hdr == "" {
		writeText(w, http.StatusForbidden, bodyAuthMissing)
		return false
	}
	const prefix = "Basic "
	if !strings.HasPrefix(hdr, prefix) {
		writeText(w, http.StatusForbidden, bodyAuthMissing)
		return false
	}
	dec, err := base64.StdEncoding.DecodeString(strings.TrimSpace(hdr[len(prefix):]))
	if err != nil {
		writeText(w, http.StatusForbidden, bodyAuthMissing)
		return false
	}
	// Constant-time compare to keep the credential check timing-safe.
	if subtle.ConstantTimeCompare(dec, []byte(expected)) != 1 {
		writeText(w, http.StatusForbidden, bodyAccessDenied)
		return false
	}
	return true
}

// sanitizeFilename strips path separators from the filename. The
// Python helper does only `filename.replace('/', '')`, so a crafted
// `../../../../etc/passwd-leak` part-name lands as
// `........etcpasswd-leak` *inside* the upload dir (it never escapes,
// just produces a strange name). Go's mime/multipart already
// basename's the part filename for us before we see it (security
// default in the stdlib parser), so the `ReplaceAll` here is
// belt-and-braces — for any path the stdlib lets through, we strip
// any residual slashes and remove any backslashes for cross-OS
// safety. The noVNC client uploads from a file picker that always
// supplies a basename, so this divergence is invisible to production
// traffic; the parity tests assert disk-state equivalence on
// well-formed uploads only.
func sanitizeFilename(name string) string {
	name = strings.ReplaceAll(name, "/", "")
	name = strings.ReplaceAll(name, "\\", "")
	return name
}

// requireIntField fetches an integer-valued multipart text field. On
// missing field, writes the BadRequestKeyError-style 400 the Python
// helper produces and returns false.
func requireIntField(values map[string][]string, key string, w http.ResponseWriter) (int, bool) {
	vs, ok := values[key]
	if !ok || len(vs) == 0 {
		writeText(w, http.StatusBadRequest, "missing form field: "+key)
		return 0, false
	}
	n, err := strconv.Atoi(vs[0])
	if err != nil {
		writeText(w, http.StatusBadRequest, "invalid integer for "+key+": "+vs[0])
		return 0, false
	}
	return n, true
}

// writeText sets Content-Type to text/html; charset=utf-8 (matching
// Werkzeug's default for str responses) and writes body without a
// trailing newline. Python's helper returns plain strings; the bytes
// on the wire are exactly len(body), no terminator.
func writeText(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", contentTypeHTML)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

// watchIdle samples the activity counter every idleTimeout/4 and
// initiates a clean shutdown when no activity is seen across a full
// idleTimeout window. The startup tick count is treated as the
// initial baseline so we don't shut down before any client connects.
func watchIdle(ctx context.Context, srv *http.Server, act *activity, idleTimeout time.Duration) {
	tick := idleTimeout / 4
	if tick < time.Second {
		tick = time.Second
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	last := act.snapshot()
	deadline := time.Now().Add(idleTimeout)
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			cur := act.snapshot()
			if cur != last {
				last = cur
				deadline = now.Add(idleTimeout)
				continue
			}
			if now.After(deadline) {
				log.Printf("idle for %s; shutting down", idleTimeout)
				shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				_ = srv.Shutdown(shutdownCtx)
				cancel()
				return
			}
		}
	}
}

func getEnvInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
