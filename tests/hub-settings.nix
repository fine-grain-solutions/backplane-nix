# VM test for services.backplane.unsupported.settings: the SettingSet line is
# appended once, the hub starts, and restarts add nothing.
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "backplane-hub-settings";

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
      unsupported.settings = {"restart.continue" = "off";};
    };

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    evlog = "/home/alice/.backplane/hub/events.jsonl"
    pat = '"$":"SettingSet","key":"restart.continue","value":"off"'

    machine.wait_for_unit("backplane.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)

    with subtest("line is written once, in the hub's format"):
        machine.succeed(f"test \"$(grep -cF '{pat}' {evlog})\" = 1")
        line = machine.succeed(f"grep -F '{pat}' {evlog}").strip()
        print(line)
        machine.succeed(f"grep -E '^\\{{\"\\$\":\"SettingSet\",\"key\":\"restart.continue\",\"value\":\"off\",\"at\":[0-9]+\\}}$' {evlog}")

    with subtest("restart adds no duplicate and leaves the file as it was"):
        before = machine.succeed(f"wc -l < {evlog}").strip()
        machine.succeed("systemctl restart backplane.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)
        machine.succeed(f"test \"$(grep -cF '{pat}' {evlog})\" = 1")
        after = machine.succeed(f"wc -l < {evlog}").strip()
        print(before, after)
        assert before == after, (before, after)

    with subtest("a changed last value is appended, not edited"):
        machine.succeed("systemctl stop backplane.service")
        machine.succeed(f"printf '%s\\n' '{{\"$\":\"SettingSet\",\"key\":\"restart.continue\",\"value\":\"on\",\"at\":1}}' >> {evlog}")
        machine.succeed("systemctl start backplane.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)
        machine.succeed(f"test \"$(grep -cF '{pat}' {evlog})\" = 2")

    with subtest("an unreadable last entry is skipped and the hub still starts"):
        machine.succeed("systemctl stop backplane.service")
        machine.succeed(f"printf '%s\\n' '{{\"$\":\"SettingSet\",\"key\":\"restart.continue\",\"value\":' >> {evlog}")
        machine.succeed("systemctl start backplane.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3787/healthz", timeout=60)
        machine.succeed("journalctl -u backplane.service | grep -F 'unsupported.settings'")
  '';
}
