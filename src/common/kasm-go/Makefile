# kasm-go build
#
# Static binaries for linux/amd64 and linux/arm64. CGO disabled so the
# result is a single self-contained executable. These ship alongside
# the upstream container-init binary (github.com/emrul/container-init).

BIN_DIR := bin
LDFLAGS := -s -w
GOFLAGS := -trimpath
TAGS    := osusergo,netgo

.PHONY: all build upload upload-amd64 upload-arm64 xvnc xvnc-amd64 xvnc-arm64 \
        test tidy clean

all: build

build: upload xvnc

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
