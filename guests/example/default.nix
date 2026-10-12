{
  modulesPath,
  lib,
  ...
}:
{
  imports = [
    # The same module the upstream NixOS incus image imports. Keeping it means
    # `nixos-rebuild switch` preserves the container-specific boot and network
    # wiring instead of clobbering it with a bare-metal system.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "example";
    # The incus image configures eth0 with systemd-networkd, not dhcpcd.
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # lxc-container.nix enables sshd via mkDefault, but state it explicitly so a
  # deploy can never lock us out of the instance.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Root SSH access for `nixos-rebuild --target-host root@<instance-ip>`.
  # The first deploy needs this key seeded out-of-band (README > Deploy);
  # afterwards this declaration keeps it in place.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoqhLqzuQJEyn/M4WmBkpPlMou2zIXoJUikAcFgvx4C peteresselius@Fox.lan"
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The guest must never build - builds run on the Mac's linux-builder. With
    # max-jobs = 0 nix only substitutes, so any attempt to build inside the
    # container fails.
    max-jobs = 0;
  };

  system.stateVersion = "26.05";
}
