{
  description = "Booted NixOS normal-user installation gate";
  inputs.installer.url = "path:../../dearmachine-concierge";
  inputs.nixpkgs.follows = "installer/nixpkgs";
  outputs = { self, nixpkgs, installer }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    runtime = installer.packages.${system}.default;
  in {
    checks.${system}.installation = pkgs.testers.runNixOSTest {
      name = "dearmachine-nixos-user-installation";
      nodes.machine = { pkgs, ... }: {
        virtualisation.memorySize = 3072;
        virtualisation.diskSize = 12000;
        virtualisation.useNixStoreImage = true;
        virtualisation.writableStore = true;
        virtualisation.writableStoreUseTmpfs = false;
        users.users.installer = { isNormalUser = true; uid = 1000; };
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        system.extraDependencies = [ runtime ];
        environment.systemPackages = [ pkgs.util-linux pkgs.expect ];
        system.stateVersion = "26.05";
      };
      testScript = ''
        machine.start(allow_reboot=True)
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep '^ID=nixos' /etc/os-release")
        machine.succeed("su - installer -c 'nix profile install --offline ${runtime}'")
        machine.succeed("su - installer -c 'dearmachine --help'")
        machine.succeed("su - installer -c 'machtiani-model-host --help'")
        # A normal user's service must survive a stop/start and a guest reboot.
        machine.succeed("loginctl enable-linger installer")
        machine.wait_for_unit("user@1000.service")
        machine.succeed("su - installer -c 'mkdir -p ~/.config/systemd/user; printf \"[Service]\\nExecStart=${pkgs.coreutils}/bin/sleep infinity\\n[Install]\\nWantedBy=default.target\\n\" > ~/.config/systemd/user/installation-probe.service'")
        userctl = "su - installer -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user "
        machine.succeed(userctl + "enable --now installation-probe.service'")
        machine.succeed(userctl + "restart installation-probe.service'")
        machine.succeed(userctl + "is-active installation-probe.service'")
        machine.reboot()
        machine.wait_for_unit("user@1000.service")
        machine.succeed(userctl + "is-active installation-probe.service'")
        machine.succeed("su - installer -c 'dearmachine --help'")
        machine.succeed(userctl + "disable --now installation-probe.service'")
      '';
    };
  };
}
