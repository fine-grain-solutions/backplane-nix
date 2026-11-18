{
  description = "Backplane (https://github.com/BackplaneWorks/Backplane) for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    overlay = final: _prev: {
      backplane-kistack = final.callPackage ./pkgs/kistack.nix {};
      backplane = final.callPackage ./pkgs/backplane.nix {kistack = final.backplane-kistack;};
      backplane-kicad = final.callPackage ./pkgs/backplane-kicad.nix {};
    };
  in {
    overlays.default = overlay;

    packages = forAllSystems (system: pkgs: let
      withOverlay = pkgs.extend overlay;
    in
      {
        inherit (withOverlay) backplane;
        kistack = withOverlay.backplane-kistack;
        default = withOverlay.backplane;
      }
      // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        inherit (withOverlay) backplane-kicad;
      });

    nixosModules = {
      default = import ./modules/nixos/backplane.nix self;
      backplane = self.nixosModules.default;
    };

    checks = forAllSystems (system: pkgs:
      nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        hub = import ./tests/hub.nix {inherit self pkgs;};
      }
      // {
        inherit (self.packages.${system}) backplane;
      });

    formatter = forAllSystems (_: pkgs: pkgs.alejandra);
  };
}
