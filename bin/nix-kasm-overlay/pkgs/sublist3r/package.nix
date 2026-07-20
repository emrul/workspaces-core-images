# Sublist3r — subdomain enumeration (Trace Labs OSINT). Not in nixpkgs.
# Pinned to tag 1.1 (latest release; git 6af1b8c). requirements: requests +
# dnspython (argparse/subbrute are stdlib/bundled). See design/tracelabs-osint-image.md §4.
{ prev }:
let
  lib = prev.lib;
in
prev.python3Packages.buildPythonApplication {
  pname = "sublist3r";
  version = "1.1";
  format = "setuptools";

  src = prev.fetchFromGitHub {
    owner = "aboul3la";
    repo = "Sublist3r";
    rev = "1.1";
    hash = "sha256-X1p5lCIZTU+xZZSsNtf/liiqkDlgaufY8hC4ZDqF6cw=";
  };

  propagatedBuildInputs = with prev.python3Packages; [
    requests
    dnspython
  ];

  doCheck = false; # no test suite; enumeration hits the network

  meta = with lib; {
    description = "Fast subdomains enumeration tool for penetration testers";
    homepage = "https://github.com/aboul3la/Sublist3r";
    license = licenses.gpl2Only;
    mainProgram = "sublist3r";
  };
}
