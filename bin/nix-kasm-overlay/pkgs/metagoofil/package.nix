# metagoofil — document metadata harvester (Trace Labs OSINT). Not in nixpkgs.
# Pinned to v1.4.0 (8d50624). A bare single-file script (no setup.py), so wrap
# python3 + deps via makeWrapper. Dep `googlesearch` is provided by the PyPI
# `google` 3.0.0 package (in nixpkgs as python3Packages.google), NOT
# googlesearch-python. See design/tracelabs-osint-image.md §4.
{ prev }:
let
  inherit (prev) lib python3 fetchFromGitHub makeWrapper stdenvNoCC;
  pythonEnv = python3.withPackages (ps: [
    ps.requests
    ps.google # PyPI "google" 3.0.0 -> provides the `googlesearch` module
  ]);
in
stdenvNoCC.mkDerivation rec {
  pname = "metagoofil";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "opsdisk";
    repo = "metagoofil";
    rev = "v${version}";
    hash = "sha256-EY3DHSevIcBOkXIy19l3UDT72DvDU9FfqLZuFV7H7uo=";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/metagoofil
    cp metagoofil.py $out/share/metagoofil/metagoofil.py
    cp -r user_agents.txt $out/share/metagoofil/ 2>/dev/null || true
    makeWrapper ${pythonEnv}/bin/python $out/bin/metagoofil \
      --add-flags "$out/share/metagoofil/metagoofil.py"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Metadata/document harvester (OSINT) for documents exposed on a target domain";
    homepage = "https://github.com/opsdisk/metagoofil";
    license = licenses.gpl3Only;
    mainProgram = "metagoofil";
    platforms = platforms.all;
  };
}
