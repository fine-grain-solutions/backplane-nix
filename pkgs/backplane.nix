# Backplane: the upstream native release (hub, desktop window, guard),
# patched to run on NixOS.
#
# The archive is flat and holds prebuilt programs. Everything is installed
# as one folder in $out/libexec/backplane, because the hub finds its
# companions (kistack, assets) next to its own binary. $out/bin only has
# links into it.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  addDriverRunpath,
  # runtime libraries
  fontconfig,
  freetype,
  libGL,
  libxkbcommon,
  vulkan-loader,
  wayland,
  libx11,
  libxcb,
  libxau,
  libxdmcp,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxcursor,
  libxi,
  libxrender,
  libgbm,
  libdrm,
  glib,
  nss,
  nspr,
  atk,
  at-spi2-core,
  dbus,
  cups,
  expat,
  cairo,
  pango,
  systemdLibs,
  alsa-lib,
  # KiStack skills linked next to the hub (null: none)
  kistack ? null,
}: let
  version = "0.15.0";
  tag = "v${version}";
  sources = {
    x86_64-linux = {
      asset = "linux-x64-native";
      hash = "sha256-McGIWYvKqnmwDdGy7gvYAAFNR4GLWPsGbcHr+VrNvOM=";
    };
    aarch64-linux = {
      asset = "linux-arm64-native";
      hash = "sha256-HVHm6gocZebD6F3FiZOeycLa/FvOlX+qcFmTMEaUwmQ=";
    };
  };
  source = sources.${stdenv.hostPlatform.system} or (throw "backplane: unsupported system ${stdenv.hostPlatform.system}");
  # Libraries the desktop window opens at run time (windowing, GPU, fonts).
  windowLibs = [
    fontconfig.lib
    freetype
    libGL
    libxkbcommon
    vulkan-loader
    wayland
    libx11
    libxcb
    libxau
    libxdmcp
    libxcursor
    libxi
    libxrandr
    libxrender
    libxext
    libxfixes
  ];
  # libcef.so is linked into backplane-gpui, so its own dependencies must
  # resolve for the window to load. The embedded browser is not started by
  # the headless hub.
  cefLibs = [
    glib
    nss
    nspr
    atk
    at-spi2-core
    dbus
    cups
    expat
    cairo
    pango
    systemdLibs
    alsa-lib
    libgbm
    libdrm
    libxcomposite
    libxdamage
  ];
in
  stdenv.mkDerivation {
    pname = "backplane";
    inherit version;

    src = fetchurl {
      url = "https://github.com/BackplaneWorks/Backplane/releases/download/${tag}/backplane-${tag}-${source.asset}.tar.gz";
      inherit (source) hash;
    };

    # The archive has no top-level folder.
    sourceRoot = ".";
    unpackPhase = ''
      runHook preUnpack
      mkdir -p unpacked
      tar -xzf $src -C unpacked
      cd unpacked
      runHook postUnpack
    '';

    nativeBuildInputs = [autoPatchelfHook makeWrapper addDriverRunpath];
    buildInputs = [stdenv.cc.cc.lib] ++ windowLibs ++ cefLibs;
    # Opened with dlopen, so they are not in the programs' NEEDED lists.
    runtimeDependencies = windowLibs;

    # backplane-browser and backplane-step2glb are Bun single-file programs.
    # Their script payload is appended to the ELF file, so they are not
    # patched (see postFixup) and are left as shipped.
    dontStrip = true;
    dontPatchELF = true;
    autoPatchelfIgnoreMissingDeps = ["libcuda.so.1"];

    installPhase = ''
      runHook preInstall
      dest=$out/libexec/backplane
      mkdir -p $dest $out/bin
      cp -a . $dest/
      ${lib.optionalString (kistack != null) ''
        ln -s ${kistack} $dest/kistack
      ''}
      # Use the system's Vulkan loader (it knows where NixOS keeps GPU
      # drivers) instead of the copy shipped for the embedded browser.
      ln -sf ${vulkan-loader}/lib/libvulkan.so.1 $dest/libvulkan.so.1
      for prog in backplane backplane-hub backplane-gpui backplane-voice; do
        ln -s $dest/$prog $out/bin/$prog
      done
      runHook postInstall
    '';

    # Patch by hand so the Bun programs can be skipped.
    dontAutoPatchelf = true;
    postFixup = ''
      dest=$out/libexec/backplane
      autoPatchelf \
        $dest/backplane $dest/backplane-hub $dest/backplane-gpui \
        $dest/backplane-voice $dest/libcef.so $dest/libvk_swiftshader.so
      addDriverRunpath $out/libexec/backplane/backplane-gpui
    '';

    passthru = {inherit kistack;};

    meta = {
      description = "Backplane: workspace for agent-driven CAD and software work (upstream native release)";
      homepage = "https://github.com/BackplaneWorks/Backplane";
      license = lib.licenses.mit;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = builtins.attrNames sources;
      mainProgram = "backplane-hub";
    };
  }
