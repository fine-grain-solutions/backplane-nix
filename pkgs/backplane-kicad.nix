# Backplane's KiCad fork (https://github.com/BackplaneWorks/Backplane_KiCad):
# KiCad 10.99 plus the headless IPC server (`kicad-cli api-server`).
#
# The pinned release is the one Backplane 0.15.0 itself installs on Linux
# (10.99.0-bp.4). Backplane treats a `kicad-cli` as the fork when
# <root>/manifest.json is next to <root>/bin, so the layout of the release
# is kept.
#
# The bundle carries its own glibc and loader, and every program is started
# as `lib/ld-linux-x86-64.so.2 --library-path lib bin/<prog>.real`. For that
# reason it is not patched, stripped or shebang-patched as a whole; only the
# launcher scripts are adjusted.
#
# The stock symbol, footprint and 3D-model libraries are left out of the
# unpack (several GB). The launchers use nixpkgs' KiCad library packages
# instead. A caller's KICAD10_*_DIR still wins, as in the upstream launcher.
{
  lib,
  stdenvNoCC,
  fetchurl,
  kicad,
  runtimeShell,
}: let
  release = "backplane-kicad-v10.99.0-bp.4";
  libs = kicad.libraries;
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "backplane-kicad";
    version = "10.99.0-bp.4";

    src = fetchurl {
      url = "https://github.com/BackplaneWorks/Backplane_KiCad/releases/download/${release}/backplane-kicad-linux-x86_64-${finalAttrs.version}.tar.gz";
      # sha256 f60a71817d057f9dcf3faef632b2f85d06a613108dee23807c9de81aae97e0b4
      # is the value Backplane 0.15.0 checks for this release.
      hash = "sha256-9gpxgX0Ff53PP672MrL4XQamExCN7iOAfJ3oGq6X4LQ=";
    };

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;
    dontPatchShebangs = true;
    noAuditTmpdir = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      tar -xzf $src -C $out --strip-components=1 \
        --exclude='*/share/kicad/3dmodels' \
        --exclude='*/share/kicad/symbols' \
        --exclude='*/share/kicad/footprints' \
        --exclude='*/share/kicad/demos'

      grep -q '"apiVersion"' $out/manifest.json

      # The launchers are identical sh scripts beside each <prog>.real.
      for f in $out/bin/*; do
        [ -e "$f.real" ] || continue
        grep -q 'ld-linux-x86-64.so.2' "$f" || { echo "unexpected launcher $f"; exit 1; }
        substituteInPlace "$f" \
          --replace-fail '#!/usr/bin/env sh' '#!${runtimeShell}' \
          --replace-fail 'root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' "root=$out" \
          --replace-fail '$root/share/kicad/symbols' '${libs.symbols}/share/kicad/symbols' \
          --replace-fail '$root/share/kicad/footprints' '${libs.footprints}/share/kicad/footprints' \
          --replace-fail '$root/share/kicad/3dmodels' '${libs.packages3d}/share/kicad/3dmodels'
      done
      test -x $out/bin/kicad-cli.real
      runHook postInstall
    '';

    meta = {
      description = "Backplane's KiCad fork with the headless IPC API server (release binary)";
      homepage = "https://github.com/BackplaneWorks/Backplane_KiCad";
      license = lib.licenses.gpl3Plus;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["x86_64-linux"];
      mainProgram = "kicad-cli";
    };
  })
