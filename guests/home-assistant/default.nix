{
  modulesPath,
  lib,
  pkgs,
  pyproject-nix-lib,
  ...
}:
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "home-assistant";
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
  # deploy can never lock us out. openFirewall adds a global port-22 allow, so
  # keep it off and open ports per-interface below.
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
    # container fails.
    max-jobs = 0;
  };

  services.home-assistant = {
    enable = true;
    customComponents = [
      (pkgs.callPackage ../../pkgs/audi_connect_ha.nix { })
      (pkgs.callPackage ../../pkgs/easee_hass.nix { inherit pyproject-nix-lib; })
    ];
    extraComponents = [
      "zha"
      "google_translate"
      "mqtt"
      "cast"
      "homekit"
      "homekit_controller"
      "webostv"
      "apple_tv"
      "prometheus"
      "caldav"
      "plex"
      "spotify"
      "recorder"
      "history"
      "energy"
      "logbook"
      "oralb"
      "zeroconf"
      "switchbot"
      "ibeacon"
      "dlna_dmr"
      "icloud"
    ];
    config = {
      default_config = { };
      http = {
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" ];
      };
      # Recorder -> local PostgreSQL over the unix socket (peer auth as the
      # `hass` user). SQLite is too slow for the recorder.
      recorder.db_url = "postgresql://@/hass";
      prometheus.requires_auth = false;
    };
    extraPackages =
      p: with p; [
        # Recorder -> postgres
        psycopg2
        getmac
        kegtron-ble
        python-roborock
      ];
  };

  # Recorder backend, co-located with HA (no dedicated postgres guest).
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "hass" ];
    ensureUsers = [
      {
        name = "hass";
        ensureDBOwnership = true;
      }
    ];
  };

  # Disabled until the cutover: the module's target is what pulls HA in, so
  # drop the target from multi-user.target - HA never starts (and can't clash
  # with adama's) until it is cut over.
  systemd.targets.home-assistant.wantedBy = lib.mkForce [ ];

  # `.dev` is HSTS-preloaded, so the UI must be HTTPS. nginx terminates TLS on
  # :443 (and serves the http-01 challenge on :80), proxying to HA on loopback.
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.int.esselius.dev:8443/acme/internal/directory";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."home-assistant.int.esselius.dev" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8123";
        proxyWebsockets = true;
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the UI) and SSH - only on the
  # private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
