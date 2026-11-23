# NixOS module for Backplane.
#
#   services.backplane  the headless hub as a systemd service for one user
#   programs.backplane  the desktop window, installed system-wide
#
# Only documented interfaces are used: the hub's command-line flags
# (`backplane-hub --help`) and the environment variables named below, each
# with the upstream doc (at tag v0.15.0) that describes it.
#
# The module never writes inside the hub's data folder. It may create the
# folder itself (mode 0700, owned by the user) and nothing else. The one
# exception is the off-by-default `unsupported.settings` option.
flake: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.services.backplane;
  pcfg = config.programs.backplane;
  system = pkgs.stdenv.hostPlatform.system;

  # An absolute path that is given as a string, so Nix never copies it into
  # the store. Store paths are refused: nothing secret may end up there.
  absPath =
    types.addCheck types.str (p: lib.hasPrefix "/" p && !lib.hasPrefix "/nix/store/" p)
    // {
      name = "absPath";
      description = "absolute path outside /nix/store";
      descriptionClass = "noun";
    };

  # Programs the hub runs through a shell (project discovery, archives,
  # process listing, PDF previews, ...). The default service PATH has only
  # coreutils, findutils, grep, sed and systemd, and a missing tool fails
  # without a clear message, so they are listed here.
  hubTools = with pkgs; [
    coreutils
    bash
    gnugrep
    gnused
    gawk
    findutils
    gnutar
    gzip
    procps
    hostname
    util-linux
    poppler-utils
    which
    git
    curl
  ];

  # The hub takes `kicad-cli` from PATH (and FreeCAD from
  # BACKPLANE_FREECAD or PATH). Backplane counts a `kicad-cli` as its fork
  # when <root>/manifest.json is beside <root>/bin, so the fork is exposed
  # as a small root that holds just those two entries. Putting it before
  # nixpkgs KiCad on PATH makes it win without hiding the other programs.
  forkRoot = pkg:
    pkgs.linkFarm "backplane-kicad-root" [
      {
        name = "bin/kicad-cli";
        path = "${pkg}/bin/kicad-cli";
      }
      {
        name = "manifest.json";
        path = "${pkg}/manifest.json";
      }
    ];

  # Backplane package with the selected KiStack skills next to the hub.
  withKistack = c:
    if c.package ? override
    then
      c.package.override {
        kistack =
          if c.kistack.enable
          then c.kistack.package
          else null;
      }
    else c.package;

  # PATH entries and environment shared by the service and the window.
  mkRuntime = c: {
    path =
      lib.optional (c.kicad.enable && c.kicad.fork.enable) "${forkRoot c.kicad.fork.package}"
      ++ lib.optional c.kicad.enable c.kicad.package
      ++ lib.optional c.freecad.enable c.freecad.package
      ++ c.extraPackages
      ++ hubTools;
    env =
      {
        # Self-update is off; versions move with this flake.
        # docs/deploy.md ("Who updates itself")
        BACKPLANE_NO_UPDATE = "1";
      }
      // lib.optionalAttrs c.freecad.enable {
        # Console executable of FreeCAD. docs/mechanical.md
        BACKPLANE_FREECAD = "${c.freecad.package}/bin/freecadcmd";
      };
  };

  # Options that the service and the program have in common.
  commonOptions = what: c: {
    package = mkOption {
      type = types.package;
      default = flake.packages.${system}.backplane;
      defaultText = lib.literalExpression "backplane-nix.packages.\${system}.backplane";
      description = "The Backplane package. ${what}";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      example = lib.literalExpression "[ pkgs.claude-code pkgs.codex ]";
      description = ''
        Packages put on PATH of Backplane and of everything it starts. Use
        this for the agent command-line tools you want to run. The module
        sets up no logins for them.
      '';
    };

    kicad = {
      enable = mkEnableOption "KiCad for Backplane (`kicad.package` on PATH)";

      package = mkOption {
        type = types.package;
        default = pkgs.kicad;
        defaultText = lib.literalExpression "pkgs.kicad";
        example = lib.literalExpression "pkgs-unstable.kicad";
        description = ''
          The KiCad put on PATH. Choose the same KiCad you use yourself, so
          that Backplane and you run one version and only one copy is
          installed.
        '';
      };

      fork = {
        enable = mkEnableOption ''
          Backplane's KiCad fork instead of nixpkgs KiCad for `kicad-cli`.
          The fork has the headless IPC server (`kicad-cli api-server`) that
          Backplane's board and schematic tools use. x86_64-linux only.
          Needs `kicad.enable`'';

        package = mkOption {
          type = types.package;
          default = flake.packages.${system}.backplane-kicad;
          defaultText = lib.literalExpression "backplane-nix.packages.x86_64-linux.backplane-kicad";
          description = "The KiCad fork. Its root needs bin/kicad-cli and manifest.json.";
        };
      };
    };

    freecad = {
      enable =
        mkEnableOption "FreeCAD for Backplane (`freecad.package` on PATH, BACKPLANE_FREECAD set)"
        // {
          default = c.kicad.enable;
          defaultText = lib.literalExpression "kicad.enable";
        };

      package = mkOption {
        type = types.package;
        default = pkgs.freecad;
        defaultText = lib.literalExpression "pkgs.freecad";
        description = "The FreeCAD whose `freecadcmd` Backplane uses.";
      };
    };

    kistack = {
      enable =
        mkEnableOption ''
          the KiStack KiCad skills, placed next to the Backplane binaries
          where the hub looks for them
        ''
        // {default = true;};

      package = mkOption {
        type = types.package;
        default = flake.packages.${system}.kistack;
        defaultText = lib.literalExpression "backplane-nix.packages.\${system}.kistack";
        description = "KiStack skills. The folder needs a `skills` directory.";
      };
    };
  };

  # Unsupported: appends SettingSet lines to the hub's event log before each
  # start (the hub is not running then). Only used when
  # `unsupported.settings` is not empty. It never fails the start: a key
  # whose last entry cannot be read is skipped with a warning.
  settingsFile = pkgs.writeText "backplane-settings.json" (builtins.toJSON cfg.unsupported.settings);
  applySettings = pkgs.writeShellScript "backplane-apply-settings" ''
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.gnugrep pkgs.jq]}
    log=${lib.escapeShellArg cfg.dataDir}/events.jsonl
    warn() { echo "backplane: unsupported.settings: $*" >&2; }
    jq -r 'keys[]' ${settingsFile} | while IFS= read -r key; do
      value=$(jq -r --arg k "$key" '.[$k]' ${settingsFile})
      keyjson=$(jq -nc --arg k "$key" '$k')
      last=
      if [ -s "$log" ]; then
        last=$(grep -F '"$":"SettingSet"' "$log" | grep -F "\"key\":$keyjson," | tail -n 1)
      fi
      if [ -n "$last" ]; then
        current=$(printf '%s\n' "$last" | jq -er 'select(.["$"] == "SettingSet" and .key == $k) | .value | strings' --arg k "$key")
        if [ $? -ne 0 ]; then
          warn "cannot read the last entry for \"$key\"; skipped"
          continue
        fi
        [ "$current" = "$value" ] && continue
      fi
      line=$(jq -nc --arg k "$key" --arg v "$value" --arg at "$(date +%s)" \
        '{"$": "SettingSet", key: $k, value: $v, at: ($at | tonumber)}') || {
        warn "cannot build the entry for \"$key\"; skipped"
        continue
      }
      # Start on a new line if the file does not end with one.
      if [ -s "$log" ] && [ -n "$(tail -c 1 "$log")" ]; then
        printf '\n' >> "$log" || { warn "cannot write $log; skipped"; continue; }
      fi
      printf '%s\n' "$line" >> "$log" || warn "cannot write $log; \"$key\" skipped"
    done
    exit 0
  '';

  tailscaleFlag = {
    off = "--no-tailscale";
    tailnet = "--tailscale";
    tailnet-https = "--tailscale-https";
    tailnet-only = "--tailnet-only";
  };
in {
  options.services.backplane =
    {
      enable = mkEnableOption "the Backplane hub as a headless service";

      user = mkOption {
        type = types.str;
        example = "alice";
        description = ''
          The user the hub runs as. Agent tools it starts run with this
          user's rights and use this user's home directory. The user must
          exist.
        '';
      };

      group = mkOption {
        type = types.str;
        default = config.users.users.${cfg.user}.group;
        defaultText = lib.literalExpression "config.users.users.\${user}.group";
        description = "The group the hub runs as.";
      };

      dataDir = mkOption {
        type = absPath;
        default = "${config.users.users.${cfg.user}.home}/.backplane/hub";
        defaultText = lib.literalExpression ''"''${config.users.users.''${user}.home}/.backplane/hub"'';
        description = ''
          Backplane's data folder (`--home`). The module creates it empty
          (mode 0700, owned by the user) and never writes inside it, unless
          `unsupported.settings` is set. Event log, settings and pairing
          token are managed by Backplane.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 3787;
        description = "Port of the hub. It always listens on 127.0.0.1.";
      };

      tailscale = mkOption {
        type = types.enum ["off" "tailnet" "tailnet-https" "tailnet-only"];
        default = "off";
        description = ''
          Whether and how the hub is also reachable over Tailscale. The
          hub still binds 127.0.0.1 only; Tailscale access is Backplane's
          own listener on the tailnet address.

          - `off`: loopback only (`--no-tailscale`).
          - `tailnet`: also on the tailnet address (`--tailscale`).
          - `tailnet-https`: also behind `tailscale serve` with HTTPS
            (`--tailscale-https`).
          - `tailnet-only`: only on the tailnet, behind `tailscale serve`
            (`--tailnet-only`). See Backplane's docs/pairing.md.

          Any value but `off` needs `services.tailscale.enable`.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open `port` on the Tailscale interface only (never on other
          interfaces). Needs `tailscale` to be set to a value but `off`.
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr absPath;
        default = null;
        example = "/run/secrets/backplane.env";
        description = ''
          A file of `NAME=value` lines loaded as the unit's
          `EnvironmentFile`, for example API keys of agent tools. It is a
          runtime path: it is never copied into the Nix store, and paths
          below /nix/store are refused.
        '';
      };

      unsupported.settings = mkOption {
        type = types.attrsOf types.str;
        default = {};
        example = {"restart.continue" = "off";};
        description = ''
          **Unsupported.** Settings applied before each hub start by
          appending `SettingSet` lines to `<dataDir>/events.jsonl`. This
          writes Backplane's internal event log, which is not a documented
          interface. It was observed to work with Backplane 0.15.0 and 0.16.4 (the hub
          replays `SettingSet` lines from `events.jsonl` at start). It may
          break or corrupt state on other versions. Prefer changing settings
          in Backplane's Settings.

          For each key, a line is appended only if the last `SettingSet`
          for it is missing or has another value. Existing lines are never
          changed. A key whose last entry cannot be read is skipped with a
          warning in the journal; the hub start never fails because of this
          option. With the default `{}` nothing is written.
        '';
      };
    }
    // commonOptions "Used for the hub." cfg;

  options.programs.backplane =
    {
      enable = mkEnableOption "the Backplane desktop window (`backplane` launcher)";
    }
    // commonOptions "Used for the desktop window." pcfg;

  config = mkMerge [
    (mkIf cfg.enable (let
      runtime = mkRuntime cfg;
      pkg = withKistack cfg;
    in {
      assertions = [
        {
          assertion = cfg.user != "";
          message = "services.backplane.user must be set.";
        }
        {
          assertion = cfg.user == "" || config.users.users ? ${cfg.user};
          message = "services.backplane.user: the user \"${cfg.user}\" is not defined in users.users.";
        }
        {
          assertion = !cfg.kicad.fork.enable || cfg.kicad.enable;
          message = "services.backplane.kicad.fork.enable needs services.backplane.kicad.enable.";
        }
        {
          assertion = !cfg.kicad.fork.enable || system == "x86_64-linux";
          message = "Backplane's KiCad fork is only packaged for x86_64-linux.";
        }
        {
          assertion = cfg.tailscale == "off" || config.services.tailscale.enable;
          message = "services.backplane.tailscale = \"${cfg.tailscale}\" needs services.tailscale.enable.";
        }
        {
          assertion = !cfg.openFirewall || cfg.tailscale != "off";
          message = "services.backplane.openFirewall only opens the Tailscale interface, so tailscale must not be \"off\".";
        }
      ];

      warnings = lib.optional (pcfg.enable && cfg.port == 3787) ''
        programs.backplane and services.backplane are both enabled and the
        hub uses port 3787, which the desktop window's own hub uses by
        default. Set services.backplane.port to another port.
      '';

      networking.firewall.interfaces = mkIf (cfg.openFirewall && cfg.tailscale != "off") {
        ${config.services.tailscale.interfaceName}.allowedTCPPorts = [cfg.port];
      };

      systemd.services.backplane = {
        description = "Backplane hub";
        wantedBy = ["multi-user.target"];
        after = ["network.target"] ++ lib.optional (cfg.tailscale != "off") "tailscaled.service";
        wants = lib.optional (cfg.tailscale != "off") "tailscaled.service";

        path = runtime.path ++ lib.optional (cfg.tailscale != "off") config.services.tailscale.package;
        environment = runtime.env;

        serviceConfig =
          {
            User = cfg.user;
            Group = cfg.group;
            # Create the data folder (and missing parents) as the user, then
            # leave it alone. `install -d` changes nothing inside it.
            ExecStartPre =
              ["${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg cfg.dataDir}"]
              ++ lib.optional (cfg.unsupported.settings != {}) "-${applySettings}";
            ExecStart = lib.escapeShellArgs [
              "${pkg}/bin/backplane-hub"
              "--home"
              cfg.dataDir
              "--host"
              "127.0.0.1"
              "--port"
              (toString cfg.port)
              "--headless"
              "--foreground"
              tailscaleFlag.${cfg.tailscale}
            ];
            Restart = "on-failure";
            RestartSec = 5;

            # The hub starts agent tools with the user's rights, so the
            # sandbox stays loose: no private /tmp, no read-only home, no
            # NoNewPrivileges. These settings protect the system itself.
            ProtectSystem = "full";
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            RestrictRealtime = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK"];
          }
          // lib.optionalAttrs (cfg.environmentFile != null) {
            EnvironmentFile = cfg.environmentFile;
          };
      };
    }))

    (mkIf pcfg.enable (let
      runtime = mkRuntime pcfg;
      pkg = withKistack pcfg;
      launcher = pkgs.writeShellScriptBin "backplane" ''
        ${lib.concatStrings (lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}\n") runtime.env)}
        export PATH=${lib.makeBinPath runtime.path}''${PATH:+:$PATH}
        exec ${pkg}/bin/backplane-gpui "$@"
      '';
      desktopItem = pkgs.makeDesktopItem {
        name = "backplane";
        desktopName = "Backplane";
        exec = "backplane";
        icon = "${pkg}/libexec/backplane/assets/icon/backplane-desktop-256.png";
        categories = ["Development"];
      };
    in {
      assertions = [
        {
          assertion = !pcfg.kicad.fork.enable || pcfg.kicad.enable;
          message = "programs.backplane.kicad.fork.enable needs programs.backplane.kicad.enable.";
        }
        {
          assertion = !pcfg.kicad.fork.enable || system == "x86_64-linux";
          message = "Backplane's KiCad fork is only packaged for x86_64-linux.";
        }
      ];
      environment.systemPackages = [launcher desktopItem];
    }))
  ];
}
