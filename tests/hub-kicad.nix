# VM test: the hub with Backplane's KiCad fork and KiStack. Checks, from
# outside the hub, what its process sees: PATH, environment and the folder
# next to the hub binary.
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "backplane-hub-kicad";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.default];

    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };

    services.backplane = {
      enable = true;
      user = "alice";
      kicad.enable = true;
      kicad.package = pkgs.kicad-small;
      kicad.fork.enable = true;
      kistack.enable = true;
      freecad.enable = false;
    };

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    machine.wait_for_unit("backplane.service")
    machine.wait_for_open_port(3787, "127.0.0.1")

    with subtest("hub answers without pairing"):
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)
        machine.succeed("curl -fsS http://127.0.0.1:3787/hello")

    pid = machine.succeed("systemctl show -p MainPID --value backplane.service").strip()
    assert pid != "0", "hub has no main process"
    env = {}
    for line in machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v

    with subtest("kicad-cli resolves first to the fork root"):
        entries = [e for e in env["PATH"].split(":") if e]
        have = [e for e in entries if machine.execute(f"test -x {e}/kicad-cli")[0] == 0]
        print("PATH entries with kicad-cli:", have)
        assert have, "no kicad-cli on PATH: " + env["PATH"]
        root = have[0].rsplit("/bin", 1)[0]
        assert have[0].endswith("/bin"), have[0]
        machine.succeed(f"test -f {root}/manifest.json")
        real = machine.succeed(f"readlink -f {root}/bin/kicad-cli").strip()
        assert "backplane-kicad" in real, real
        # nixpkgs KiCad is also on PATH, but behind the fork
        assert len(have) >= 2 and "kicad-small" in have[1], have
        out = machine.succeed(
            f"runuser -u alice -- env PATH={env['PATH']} sh -c 'command -v kicad-cli; kicad-cli --version'"
        )
        print(out)
        assert out.splitlines()[0] == f"{root}/bin/kicad-cli", out
        assert out.splitlines()[-1].strip(), out

    with subtest("KiStack is next to the hub binary"):
        exe = machine.succeed(f"readlink -f /proc/{pid}/exe").strip()
        folder = exe.rsplit("/", 1)[0]
        print("hub binary:", exe)
        machine.succeed(f"test -d {folder}/kistack/skills")
        skills = machine.succeed(f"ls {folder}/kistack/skills/").split()
        print("skills:", skills)
        assert len(skills) >= 1
        machine.succeed(f"find -L {folder}/kistack/skills -name SKILL.md | grep -q .")

    with subtest("FreeCAD is not configured"):
        assert "BACKPLANE_FREECAD" not in env, env
        assert not any("freecad" in e.lower() for e in env["PATH"].split(":")), env["PATH"]
        assert env.get("BACKPLANE_NO_UPDATE") == "1"

    with subtest("hub's own report, read with its token"):
        # The docs at v0.15.0 name no HTTP route that reports KiCad IPC or
        # skills status; /healthz is documented to carry version and commit
        # for a caller with the hub's credential. Read-only use of the token.
        machine.succeed("test -f /home/alice/.backplane/hub/token")
        print(machine.succeed(
            "curl -fsS -H \"Authorization: Bearer $(cat /home/alice/.backplane/hub/token)\" "
            "http://127.0.0.1:3787/healthz"
        ))
  '';
}
