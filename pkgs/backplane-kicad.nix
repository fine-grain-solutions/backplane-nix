# Backplane's KiCad fork (https://github.com/BackplaneWorks/Backplane_KiCad):
# KiCad 10.99 plus the headless IPC server (`kicad-cli api-server`).
#
# The pinned release is the one Backplane 0.16.4 itself installs on Linux
# (10.99.0-bp.13.1). Backplane treats a `kicad-cli` as the fork when
# <root>/manifest.json is next to <root>/bin, so the layout of the release
# is kept.
#
# The bundle carries its own glibc and loader, and every program is started
# as `lib/ld-linux-x86-64.so.2 --library-path lib bin/<prog>.real`. For that
# reason it is not patched, stripped or shebang-patched as a whole; only the
# launcher scripts are adjusted.
#
# By default the bundle is kept as upstream ships it, including its own
# symbol, footprint and 3D-model libraries (share/kicad/{symbols,footprints,
# 3dmodels}; KICAD_LIBRARY_SOURCES.txt names them as the 10.0.6 library tags).
# The launcher's library lines stay as upstream wrote them (`$root/share/...`);
# only `root` is set to the store path. This makes the closure several GB
# bigger.
#
# With `withLibraries = false` those three folders are left out of the unpack
# and the launchers use nixpkgs' KiCad library packages instead. In both
# cases a caller's KICAD10_*_DIR still wins, as in the upstream launcher.
# `demos` is always left out.
{
  lib,
  stdenvNoCC,
  fetchurl,
  kicad,
  runtimeShell,
  glycin-loaders,
  bubblewrap,
  withLibraries ? true,
}: let
  # The bundled GTK loads images through glycin, but the bundle ships no
  # glycin loaders (it expects the system's). Without them the GUI programs
  # abort at start ("No image loaders are configured"). glycin finds its
  # loaders through XDG_DATA_DIRS and runs them sandboxed with bwrap.
  glycinEnv = ''
    export XDG_DATA_DIRS="${glycin-loaders}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    export PATH="${bubblewrap}/bin''${PATH:+:$PATH}"
  '';
  release = "backplane-kicad-v10.99.0-bp.13.1";
  libs = kicad.libraries;
  excludeArgs = lib.optionals (!withLibraries) [
    "--exclude='*/share/kicad/3dmodels'"
    "--exclude='*/share/kicad/symbols'"
    "--exclude='*/share/kicad/footprints'"
  ];
  libraryArgs = lib.optionals (!withLibraries) [
    "--replace-fail '$root/share/kicad/symbols' '${libs.symbols}/share/kicad/symbols'"
    "--replace-fail '$root/share/kicad/footprints' '${libs.footprints}/share/kicad/footprints'"
    "--replace-fail '$root/share/kicad/3dmodels' '${libs.packages3d}/share/kicad/3dmodels'"
  ];
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "backplane-kicad";
    version = "10.99.0-bp.13.1";

    src = fetchurl {
      url = "https://github.com/BackplaneWorks/Backplane_KiCad/releases/download/${release}/backplane-kicad-linux-x86_64-${finalAttrs.version}.tar.gz";
      # sha256 c51386b0c2ec7f1abb02b1b324f03d0cfeee12cc43706c4681dad8394303e0f6
      # is the value Backplane 0.16.4 checks for this release.
      hash = "sha256-xROGsMLsfxq7ArGzJPA9DP7uEsxDcGxGgdrYOUMD4PY=";
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
        ${lib.concatMapStrings (a: a + " \\\n        ") excludeArgs}--exclude='*/share/kicad/demos'

      grep -q '"apiVersion"' $out/manifest.json

      # The launchers are identical sh scripts beside each <prog>.real.
      for f in $out/bin/*; do
        [ -e "$f.real" ] || continue
        grep -q 'ld-linux-x86-64.so.2' "$f" || { echo "unexpected launcher $f"; exit 1; }
        substituteInPlace "$f" \
          --replace-fail '#!/usr/bin/env sh' '#!${runtimeShell}' \
          --replace-fail 'root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' "root=$out" ${lib.concatStringsSep " " libraryArgs} \
          --replace-fail 'export KICAD_KIFACE_HOME=' ${lib.escapeShellArg glycinEnv}'export KICAD_KIFACE_HOME='
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
