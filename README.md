# backplane-nix

A Nix flake that sets up [Backplane](https://github.com/BackplaneWorks/Backplane)
as a user application, or as a headless hub service with clients that
connect to it.

> **Status: first working version.** It packages Backplane **0.15.0**
> only. The headless hub runs as a systemd service and is covered by a VM
> test. The desktop window is packaged and loads (all libraries resolve),
> but it has not been run on a real display yet.

## Outputs

| Output | What it is |
| --- | --- |
| `packages.<system>.backplane` | The upstream native release (hub, desktop window, guard), patched to run on NixOS, with the KiStack skills next to the hub. `x86_64-linux` and `aarch64-linux`. |
| `packages.<system>.backplane-kicad` | Backplane's KiCad fork (release `10.99.0-bp.4`, the one Backplane 0.15.0 installs) with the headless IPC server (`kicad-cli api-server`), wrapped as released. `x86_64-linux` only. |
| `packages.<system>.kistack` | The KiStack KiCad skills, pinned, in the layout Backplane expects. |
| `nixosModules.default` (alias `nixosModules.backplane`) | `services.backplane`: the hub as a systemd service for one user. `programs.backplane`: the desktop window, installed system-wide. |
| `overlays.default` | Adds `backplane`, `backplane-kicad` and `backplane-kistack` to `pkgs`. |
| `checks.<system>.hub` | A NixOS VM test that starts the hub and checks that it answers on loopback only. |
| `formatter.<system>` | alejandra. |

## Usage

Headless hub on a NixOS machine:

```nix
{
  inputs.backplane-nix.url = "github:fine-grain-solutions/backplane-nix";

  outputs = { nixpkgs, backplane-nix, ... }: {
    nixosConfigurations.cad = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        backplane-nix.nixosModules.default
        {
          services.backplane = {
            enable = true;
            user = "alice";
            tailscale = "tailnet"; # default "off": loopback only
            kicad.enable = true;
          };
        }
      ];
    };
  };
}
```

Desktop app on a NixOS workstation (same module):

```nix
{
  imports = [ backplane-nix.nixosModules.default ];
  programs.backplane.enable = true;
}
```

There is no home-manager module. The maintainers don't use home-manager
and couldn't test one. The packages work with any setup that installs
Nix packages.

Clients (the desktop app on another machine, phones) pair with the hub
from Settings → Devices, as described in Backplane's own docs.

### `services.backplane`

The unit runs
`backplane-hub --home <dataDir> --host 127.0.0.1 --port <port> --headless --foreground`
plus one Tailscale flag, with `BACKPLANE_NO_UPDATE=1`.

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Run the hub. |
| `package` | this flake's `backplane` | The Backplane package. |
| `user` | required | User the hub (and the agent tools it starts) runs as. |
| `group` | the user's group | Group of the service. |
| `dataDir` | `~user/.backplane/hub` | Backplane's data folder. The module creates it empty (0700, owned by the user) and never writes inside it. |
| `port` | `3787` | Port, always on `127.0.0.1`. |
| `tailscale` | `"off"` | `off` → `--no-tailscale`, `tailnet` → `--tailscale`, `tailnet-https` → `--tailscale-https`, `tailnet-only` → `--tailnet-only`. Anything but `off` needs `services.tailscale.enable`. |
| `openFirewall` | `false` | Open `port` on the Tailscale interface only. |
| `environmentFile` | `null` | Runtime file for systemd `EnvironmentFile=`. Absolute path, not under `/nix/store`. |
| `extraPackages` | `[]` | Packages on the hub's `PATH` (for example agent CLIs). |
| `kicad.enable` | `false` | Put `kicad.package` on `PATH`. |
| `kicad.package` | `pkgs.kicad` | The KiCad on `PATH`, for example `pkgs-unstable.kicad`. |
| `freecad.enable` | follows `kicad.enable` | Put `freecad.package` on `PATH` and set `BACKPLANE_FREECAD`. |
| `freecad.package` | `pkgs.freecad` | The FreeCAD (its `freecadcmd` is used). |
| `kicad.fork.enable` | `false` | Use Backplane's KiCad fork for `kicad-cli`. Needs `kicad.enable`. |
| `kicad.fork.package` | this flake's `backplane-kicad` | The fork. |
| `kistack.enable` | `true` | Put the KiStack skills next to the hub. |
| `kistack.package` | this flake's `kistack` | The skills. |

### `programs.backplane`

Options: `enable`, `package`, `extraPackages`, `kicad.enable`,
`kicad.package`, `kicad.fork.enable`, `kicad.fork.package`,
`freecad.enable`, `freecad.package`, `kistack.enable`,
`kistack.package`, with the same meaning as above. It installs a
`backplane` launcher (and a desktop entry) that starts `backplane-gpui`
with `BACKPLANE_NO_UPDATE=1`. If it is enabled together with
`services.backplane` on port 3787, the module warns, because the window's
own hub uses that port by default.

### KiCad, FreeCAD and the GPU

`kicad.package` defaults to `pkgs.kicad` of the system's nixpkgs. Set it to
the KiCad you already use (for example `pkgs-unstable.kicad`), so that
Backplane and you run the same version and only one KiCad is installed.
FreeCAD is large (about 7 GiB with its closure); set
`freecad.enable = false` if you don't need it.

The desktop window uses the GPU through the normal NixOS driver path
(`hardware.graphics`). It was tested on NVIDIA under GNOME Wayland.

### How KiCad and KiStack are found

Only documented environment variables are set (`BACKPLANE_NO_UPDATE`,
`BACKPLANE_FREECAD`). Backplane 0.15.0 finds `kicad-cli` on `PATH`, so the
module puts KiCad (and, with `kicad.fork.enable`, the fork first) there
instead of setting `BACKPLANE_KICAD_CLI`. It looks for the KiStack skills
in a `kistack` folder next to its binaries, so the package links them
there instead of the module setting `BACKPLANE_KISTACK`. Neither variable
is described in the 0.15.0 docs.

## Testing

```sh
nix flake check          # evaluates both systems, runs the VM test on x86_64-linux
nix build .#backplane
./result/bin/backplane-hub --help
nix build .#checks.x86_64-linux.hub -L   # only the VM test (needs KVM)
nix fmt
```

To try the module in your own configuration, add the flake as an input
(or `path:/path/to/checkout` while developing), import
`nixosModules.default`, set `services.backplane.enable = true` and
`services.backplane.user`, then `nixos-rebuild test`. Check
`systemctl status backplane` and `curl http://127.0.0.1:3787/healthz`.

## Design rules

- Never bind `0.0.0.0`. The hub listens on `127.0.0.1`, plus the tailnet
  interface when asked.
- No secrets in the Nix store. Every secret option is a runtime file path,
  and the module rejects store paths.
- Backplane's self-update is turned off (`BACKPLANE_NO_UPDATE=1`). Versions
  move by bumping this flake.
- Agent CLIs (Claude Code, Codex, ...) are the user's choice: the module
  puts the packages you list on the hub's `PATH` and handles no logins.
- Only documented interfaces: the hub's command-line flags and the
  environment variables in Backplane's docs. The module never writes the
  hub's data folder (event log, settings, tokens). Settings are changed in
  Backplane itself.

## License

[MIT](LICENSE). Backplane, its KiCad fork and KiStack keep their own
licenses; this repo only packages them.
