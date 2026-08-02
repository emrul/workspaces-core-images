# PhoneInfoga — phone-number OSINT (Trace Labs). Not in nixpkgs. Pinned to
# v2.9.0 (af83dbb). Go; NOT vendored so a real vendorHash is required. The web
# client (Vue, //go:embed client/dist/*) is not in the source tarball; seed a
# placeholder so the CLI (scan/scanners/serve/version) builds. See §4.
#
# The module graph is overridden, not upstream's. v2.9.0 shipped
# golang.org/x/crypto at the 2020 pseudo-version v0.0.0-20200622213623 and
# google.golang.org/grpc v1.47.0, which between them carry nine Critical CVEs:
# CVE-2024-45337, CVE-2026-39830/39831/39832/39833/39834, CVE-2026-42508,
# CVE-2026-46595 (x/crypto) and CVE-2026-33186 (grpc).
#
# Upgrading the tool does not fix them. The newest upstream release, v2.11.0
# (2024-02-21), still ships x/crypto v0.9.0 — below the >=0.31.0 and >=0.52.0
# these advisories require — and grpc unchanged at v1.47.0. There has been no
# release in roughly two years, so waiting is not a remediation either.
#
# So go.mod/go.sum here are ours: upstream's source at tag v2.9.0 built against
# x/crypto v0.52.0 and grpc v1.79.3. They are committed rather than generated
# in postPatch because `go mod tidy` needs the network and a non-deterministic
# resolution has no place in a build we are asking a scanner to attest.
# Regenerate with scripts in the commit message; `go mod tidy` raises the go
# directive to 1.25.0, which is why buildGoModule must supply a Go >= 1.25.
#
# Verified before committing: the root package (the only one built, see
# subPackages) compiles clean before and after, and the resulting binary parses
# a number through the local scanner. `go build ./...` reports an error in
# examples/plugin, but that is pre-existing in unmodified v2.9.0 and that
# package is not built here.
{ prev }:
let
  lib = prev.lib;
  version = "2.9.0";
in
prev.buildGoModule {
  pname = "phoneinfoga";
  inherit version;

  src = prev.fetchFromGitHub {
    owner = "sundowndev";
    repo = "phoneinfoga";
    rev = "v${version}";
    hash = "sha256-Suf1FQMuaX+7LVI7ZHYJMBLEHxMCZ1ODUAFDHAHdVpg=";
  };

  # Recomputed for the overridden module graph — upstream's hash no longer
  # applies. Regenerate from the build failure after any go.mod/go.sum change;
  # a stale value fails closed rather than vendoring silently.
  vendorHash = "sha256-iyhnPH4kSDQFOyXOxHJUmQggtLHwAZirbn7gUOJlMEI=";

  subPackages = [ "." ];

  postPatch = ''
    mkdir -p web/client/dist
    echo "<!doctype html><title>phoneinfoga</title>" > web/client/dist/index.html

    # Replace upstream's module graph with the CVE-clearing one. Copied, not
    # patched, because a diff against a 900-line go.sum is unreviewable and
    # would conflict on any upstream touch.
    cp ${./go.mod} go.mod
    cp ${./go.sum} go.sum
  '';

  ldflags = [
    "-s"
    "-w"
    "-X github.com/sundowndev/phoneinfoga/v2/build.Version=v${version}"
    "-X github.com/sundowndev/phoneinfoga/v2/build.Commit=af83dbb"
  ];

  doCheck = false; # scanner unit tests reach the network

  meta = with lib; {
    description = "Advanced information gathering & OSINT framework for phone numbers";
    homepage = "https://github.com/sundowndev/phoneinfoga";
    license = licenses.gpl3Only;
    mainProgram = "phoneinfoga";
  };
}
