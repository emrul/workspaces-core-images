# SpiderFoot — OSINT automation (Trace Labs). Not in nixpkgs. Pinned to v4.0
# (b9c345d). Packaged as a wrapped python env (no console-script setup.py).
#
# v4.0's loader is NOT tolerant of missing module deps: sf.py imports EVERY
# module in main() and sys.exit(-1) on the first failure, so the server won't
# start unless all 233 modules import. Three deps are therefore inline-packaged
# (adblockparser: absent from nixpkgs; PyPDF2 3.0.1: nixpkgs flags it insecure;
# secure 0.3.0: nixpkgs ships 1.x whose API dropped the cherrypy() call v4.0
# needs). lxml<5 pin relaxed to nixpkgs' 5.x (upstream note). pygexf omitted —
# unused in v4.0 (helpers.py uses networkx's own GEXFWriter). See §4.
{ prev }:
let
  py = prev.python3;

  adblockparser = py.pkgs.buildPythonPackage rec {
    pname = "adblockparser";
    version = "0.7";
    format = "setuptools";
    src = py.pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-ejQH3cMaKeQnMrvLBPNnfGlZv/oeqdcSr9SY4LTQmyI=";
    };
    doCheck = false;
    pythonImportsCheck = [ "adblockparser" ];
  };

  pypdf2 = py.pkgs.buildPythonPackage rec {
    pname = "PyPDF2";
    version = "3.0.1";
    pyproject = true;
    src = py.pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-p0QI9pumJx9xuTUu9O0D3FOjGqQE0ptdMfU7/s/uFEA=";
    };
    build-system = [ py.pkgs.flit-core ];
    doCheck = false;
    pythonImportsCheck = [ "PyPDF2" ];
  };

  secure03 = py.pkgs.buildPythonPackage rec {
    pname = "secure";
    version = "0.3.0";
    format = "setuptools";
    src = py.pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-bjCTnY+VvzuO/7ijbrte1X8mXa7q6QXjqpZ36lOKtk4=";
    };
    doCheck = false;
    pythonImportsCheck = [ "secure" ];
  };

  pyEnv = py.withPackages (ps: with ps; [
    # core server imports
    cherrypy
    cherrypy-cors
    cryptography
    dnspython
    netaddr
    phonenumbers
    pyopenssl
    requests
    beautifulsoup4
    publicsuffixlist
    mako
    openpyxl
    secure03
    networkx
    pyyaml
    # module deps present in nixpkgs
    lxml
    pysocks
    exifread
    ipwhois
    ipaddr
    python-whois
    python-docx
    python-pptx
    # inline-packaged module deps
    adblockparser
    pypdf2
  ]);
in
prev.stdenvNoCC.mkDerivation {
  pname = "spiderfoot";
  version = "4.0";

  src = prev.fetchFromGitHub {
    owner = "smicallef";
    repo = "spiderfoot";
    rev = "v4.0";
    hash = "sha256-LvLaKrUL+XVW6QFRh9RzCXw1DpbabIayeA0eL0eIP1s=";
  };

  nativeBuildInputs = [ prev.makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/spiderfoot
    cp -R ./. $out/share/spiderfoot/
    makeWrapper ${pyEnv}/bin/python3 $out/bin/spiderfoot \
      --add-flags "$out/share/spiderfoot/sf.py" \
      --chdir "$out/share/spiderfoot" \
      --prefix PYTHONPATH : "$out/share/spiderfoot"
    makeWrapper ${pyEnv}/bin/python3 $out/bin/spiderfoot-cli \
      --add-flags "$out/share/spiderfoot/sfcli.py" \
      --chdir "$out/share/spiderfoot" \
      --prefix PYTHONPATH : "$out/share/spiderfoot"
    runHook postInstall
  '';

  meta = with prev.lib; {
    description = "SpiderFoot OSINT automation tool";
    homepage = "https://github.com/smicallef/spiderfoot";
    license = licenses.mit;
    mainProgram = "spiderfoot";
  };
}
