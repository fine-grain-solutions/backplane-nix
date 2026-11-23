# KiStack: KiCad skills for Backplane (https://github.com/BackplaneWorks/kistack).
#
# The hub reads skills from <root>/skills and looks for <root> in a
# `kistack` folder next to its own binary. pkgs/backplane.nix links this
# package there, so it works on a read-only tree and never downloads.
{
  lib,
  runCommand,
  fetchFromGitHub,
}: let
  rev = "2c6b542d7a45b5993895764754573d1b8695953f";
  src = fetchFromGitHub {
    owner = "BackplaneWorks";
    repo = "kistack";
    inherit rev;
    hash = "sha256-AHJOmDXgaYioAoIPQ+BK8YTWkL+rB/f/dv7Vn+6dQ8k=";
  };
in
  runCommand "kistack-${builtins.substring 0 7 rev}" {
    meta = {
      description = "KiStack: KiCad skills for Backplane (pinned snapshot)";
      homepage = "https://github.com/BackplaneWorks/kistack";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  } ''
    mkdir -p $out
    cp -r ${src}/skills $out/skills
    cp ${src}/README.md ${src}/LICENSE $out/
    test -d $out/skills
  ''
