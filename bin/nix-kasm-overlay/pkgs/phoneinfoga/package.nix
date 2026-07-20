# PhoneInfoga — phone-number OSINT (Trace Labs). Not in nixpkgs. Pinned to
# v2.9.0 (af83dbb). Go; NOT vendored so a real vendorHash is required. The web
# client (Vue, //go:embed client/dist/*) is not in the source tarball; seed a
# placeholder so the CLI (scan/scanners/serve/version) builds. See §4.
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

  vendorHash = "sha256-Vdw0mqybRMwg/O3MuyVChloTQNwGBaODWUfZTKBtgr8=";

  subPackages = [ "." ];

  postPatch = ''
    mkdir -p web/client/dist
    echo "<!doctype html><title>phoneinfoga</title>" > web/client/dist/index.html
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
