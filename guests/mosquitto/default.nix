{
  modulesPath,
  config,
  pkgs,
  lib,
  ...
}:
let
  # sapcc/mosquitto-exporter isn't in nixpkgs, so build it here. It subscribes
  # to the broker's $SYS/# topics and exposes them as Prometheus metrics.
  mosquittoExporter = pkgs.buildGoModule rec {
    pname = "mosquitto-exporter";
    version = "0.8.0";
    src = pkgs.fetchFromGitHub {
      owner = "sapcc";
      repo = "mosquitto-exporter";
      rev = "e26806496667e6c2b5b704ee17e2bf01067e419b";
      hash = "sha256-t+Z+VOCDRgMc53/HFzXcNCfWv5sNLPPN9YniVcsSZXw=";
    };
    vendorHash = "sha256-fdUGkbS0io/xHbv0HLs8hzOT25RCP+dnC8MwT3sowGo=";
    meta.mainProgram = "mosquitto-exporter";
  };
in
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  # Keep systemd credentials (mosquitto's passwordFile) working without nesting;
  # see modules/lxc-credentials.nix for why and the caveat.
  local.lxc.allowSystemdCredentials = true;

  local.ksm.services = [
    "alloy"
    "mosquitto"
    "mosquitto-exporter"
  ];

  networking = {
    hostName = "mosquitto";
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
    # Second NIC (macvlan on the host's LAN uplink): a fixed LAN address so
    # WiFi/LAN clients reach the broker. Deliberately no gateway - the LAN
    # subnet is directly connected, and internet egress stays on eth0 so there
    # is only one default route. Address is outside the router's DHCP pool.
    networks."50-eth1" = lib.mkIf config.local.lan.enable {
      matchConfig.Name = "eth1";
      address = [ config.local.lan.address ];
      networkConfig.DHCP = "no";
    };
  };

  # lxc-container.nix enables sshd via mkDefault, but state it explicitly so a
  # deploy can never lock us out of the instance. openFirewall would add a
  # global port-22 allow, so keep it off and open 22 per-interface below (eth0
  # only - never the LAN NIC).
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings.PermitRootLogin = "prohibit-password";
  };
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
    # container fails (and it couldn't sandbox anyway - nesting is off).
    max-jobs = 0;
  };

  # Broker user passwords come from sops, never the (world-readable) Nix store.
  # The module hands them to mosquitto via systemd credentials (LoadCredential),
  # so the files stay root-owned. This requires `security.nesting = true` on the
  # instance (set in terraform/<name>/default.nix) - LXC's generator otherwise
  # clears LoadCredential for non-nested containers.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/mosquitto.yaml;
    secrets = {
      mqtt_z2m = { };
      mqtt_hass = { };
      mqtt_nr = { };
      mqtt_p1ib = { };
      mqtt_exporter = { };
    };
    # The exporter reads $MQTT_USER/$MQTT_PASS from its environment.
    templates."mosquitto-exporter.env".content = ''
      MQTT_USER=exporter
      MQTT_PASS=${config.sops.placeholder.mqtt_exporter}
    '';
  };

  # The listener is only reachable on the vpn/LAN NICs; the broker itself is
  # plain MQTT on 1883 (as on adama), relying on the network boundary.
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        port = 1883;
        acl = [ "pattern readwrite #" ];
        users = {
          z2m.passwordFile = config.sops.secrets.mqtt_z2m.path;
          hass.passwordFile = config.sops.secrets.mqtt_hass.path;
          nr.passwordFile = config.sops.secrets.mqtt_nr.path;
          p1ib.passwordFile = config.sops.secrets.mqtt_p1ib.path;
          # The exporter needs $SYS read access (`#` does not match `$SYS`) and
          # reads the Zigbee2MQTT topics for the mqtt-exporter in that guest.
          exporter = {
            passwordFile = config.sops.secrets.mqtt_exporter.path;
            acl = [
              "$SYS/#"
              "zigbee2mqtt/#"
            ];
          };
        };
      }
    ];
  };

  # Broker metrics for the dashboard: the exporter subscribes to $SYS/# on the
  # local broker and serves Prometheus metrics on loopback; the Alloy agent
  # scrapes it (extra alloy file) and remote-writes to the monitoring workload.
  systemd.services.mosquitto-exporter = {
    description = "Prometheus exporter for Mosquitto";
    wantedBy = [ "multi-user.target" ];
    after = [ "mosquitto.service" ];
    requires = [ "mosquitto.service" ];
    serviceConfig = {
      ExecStart = "${lib.getExe mosquittoExporter} --endpoint tcp://127.0.0.1:1883 --bind-address 127.0.0.1:9234";
      EnvironmentFile = config.sops.templates."mosquitto-exporter.env".path;
      DynamicUser = true;
      Restart = "on-failure";
    };
  };

  environment.etc."alloy/mosquitto.alloy".text = ''
    prometheus.scrape "mosquitto" {
      targets    = [{ __address__ = "127.0.0.1:9234" }]
      forward_to = [prometheus.relabel.host.receiver]
    }
  '';

  # SSH only on the private backplane (eth0, incusbr-vpn); on the LAN NIC (eth1)
  # expose just MQTT. No global ports - everything is per-interface.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    1883
  ];
  networking.firewall.interfaces.eth1 = lib.mkIf config.local.lan.enable {
    allowedTCPPorts = [ 1883 ];
  };

  system.stateVersion = "26.05";
}
