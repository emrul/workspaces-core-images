{
  description = "Steam + VirtualGL in the FHS, plus steam-run, so the launcher can vglrun the client (headless GLX)";

  # Same nixpkgs rev as the base ([nixpkgs].ref) so the faker's glibc matches
  # steam's FHS. Re-pin (nix flake update) when the base ref advances.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d407951447dcd00442e97087bf374aad70c04cea";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];   # steam is amd64-only
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

          # Steam's 32-bit VGUI2 client HARD-REQUIRES a GLX visual, which headless
          # KasmVNC/Xvnc only provides via VirtualGL. VGL must be invoked via
          # `vglrun` (a bare LD_PRELOAD segfaults the faker's constructor) and
          # ideally wrap ONLY the GL client, not steam's whole bootstrap.
          #
          # So: put VirtualGL (vglrun + faker, BOTH arches) into steam's FHS, and
          # ALSO expose steam-run (runs an arbitrary cmd in that same FHS). The
          # image's launcher then does `steam-run vglrun -d egl steam`, which
          # enters the FHS and runs Valve's steam under real vglrun — faker
          # dormant in the bootstrap, active for the client. NO profile preload.
          steamFHS = pkgs.steam.override {
            extraPkgs      = p: [ p.virtualgl ];                # vglrun + 64-bit faker
            extraLibraries = p: [ p.virtualgl p.virtualglLib ]; # faker both arches → /usr/lib64 + /usr/lib32
          };
        in {
          # symlinkJoin so the profile carries: bin/steam (Valve FHS entry, keeps
          # the .desktop/icons for the menu) AND bin/steam-run (arbitrary-cmd FHS
          # runner the launcher uses). No conflicts (different bin names).
          steam-vgl = pkgs.symlinkJoin {
            name = "steam-vgl";
            paths = [ steamFHS steamFHS.run ];
          };
          default = self.packages.${system}.steam-vgl;
        });
    };
}
