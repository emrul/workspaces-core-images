# container-init build
#
# Static binaries for linux/amd64 and linux/arm64. CGO disabled so the result
# is a single self-contained executable that runs as PID 1 in any rootfs.

PKG     := github.com/kasmtech/workspaces-core-images/container-init
BIN_DIR := bin
LDFLAGS := -s -w
GOFLAGS := -trimpath
TAGS    := osusergo,netgo

.PHONY: all build build-amd64 build-arm64 helper helper-amd64 helper-arm64 \
        upload upload-amd64 upload-arm64 xvnc xvnc-amd64 xvnc-arm64 \
        test tidy clean

all: build helper upload xvnc

build: build-amd64 build-arm64

build-amd64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/container-init.linux-amd64 ./cmd/container-init

build-arm64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/container-init.linux-arm64 ./cmd/container-init

# Spike-only test helper used by probe F. Single binary with -mode native|proxy.
# Removed in Phase 4 once real units replace the synthetic ones.
helper: helper-amd64 helper-arm64

helper-amd64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/spike-helper.linux-amd64 ./cmd/spike-helper

helper-arm64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/spike-helper.linux-arm64 ./cmd/spike-helper

# kasm-upload-server: Go drop-in replacement for the PyInstaller Flask
# helper. Phase 3 of design/work_sequence.md. Static binary, ≤8 MiB
# completion criterion.
upload: upload-amd64 upload-arm64

upload-amd64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/kasm-upload-server.linux-amd64 ./cmd/kasm-upload-server

upload-arm64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/kasm-upload-server.linux-arm64 ./cmd/kasm-upload-server

# kasm-xvnc: Phase 4.4 launcher that ports the perl `vncserver`'s
# ConstructXvncCmd to Go and exec's Xvnc directly. Bypasses the perl
# wrapper entirely on the Kasm boot path; standalone-CLI users keep
# using the perl wrapper.
xvnc: xvnc-amd64 xvnc-arm64

xvnc-amd64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/kasm-xvnc.linux-amd64 ./cmd/kasm-xvnc

xvnc-arm64:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' \
		-o $(BIN_DIR)/kasm-xvnc.linux-arm64 ./cmd/kasm-xvnc

test:
	go test ./...

tidy:
	go mod tidy

clean:
	rm -rf $(BIN_DIR)
