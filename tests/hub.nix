# VM test: the hub starts as a normal user, answers on loopback only, and
# the data folder has the expected owner and mode.
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "backplane-hub";

  nodes.machine = {...}: {
    imports = [self.nixosModules.default];

    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };

    services.backplane = {
      enable = true;
      user = "alice";
      port = 3787;
    };

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.wait_for_unit("backplane.service")
    machine.wait_for_open_port(3787, "127.0.0.1")

    with subtest("hub answers without pairing"):
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)
        machine.succeed("curl -fsS http://127.0.0.1:3787/hello")

    with subtest("runs as the normal user"):
        pid = machine.succeed("systemctl show -p MainPID --value backplane.service").strip()
        machine.succeed(f"test \"$(stat -c %U /proc/{pid})\" = alice")
        env = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
        assert "BACKPLANE_NO_UPDATE=1" in env, env

    with subtest("listens on loopback only"):
        listeners = machine.succeed("ss -H -ltn")
        print(listeners)
        assert "127.0.0.1:3787" in listeners, listeners
        # every TCP listener (the hub's own included) is on 127.0.0.1
        for line in listeners.splitlines():
            local = line.split()[3]
            assert local.startswith("127.0.0.1:"), f"non-loopback listener: {line}"

    with subtest("data folder is private and owned by the user"):
        machine.succeed("test \"$(stat -c '%a %U' /home/alice/.backplane/hub)\" = '700 alice'")
  '';
}
