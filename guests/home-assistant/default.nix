{
  modulesPath,
  config,
  lib,
  pkgs,
  pyproject-nix-lib,
  ...
}:
let
  # Port of the existing UI-configured HomeKit bridge ("HASS Bridge"), stored in
  # .storage/core.config_entries. Change this if the bridge's port is changed.
  homekitPort = 21064;
in
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
    # Second NIC (macvlan on the host's LAN uplink) so HA can discover and
    # reach LAN-only devices (cast, homekit, zeroconf, dlna, ...). Fixed LAN
    # address, deliberately no gateway: the LAN is directly connected and
    # egress stays on eth0, so there is only one default route.
    networks."50-eth1" = lib.mkIf config.local.lan.enable {
      matchConfig.Name = "eth1";
      address = [ config.local.lan.address ];
      networkConfig.DHCP = "no";
      # HA picks the interface that routes 224.0.0.251 as its "default" for
      # mDNS/zeroconf and HomeKit advertisement. Without this, that is eth0
      # (the default route), so the bridge never advertises on the LAN and the
      # Home app cannot discover it. Keep egress on eth0; this only steers
      # multicast-address source selection to the LAN NIC.
      routes = [
        {
          Destination = "224.0.0.251/32";
          Scope = "link";
        }
      ];
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

  # sops key for the shared restic backup credentials (see modules/backup.nix).
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Back up the HA config dir plus a consistent pg_dump of the recorder.
  local.backup = {
    paths = [
      "/var/lib/hass"
      "/var/backup"
    ];
    prepareCommand = ''
      ${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${config.services.postgresql.package}/bin/pg_dump -Fc -f /var/backup/hass.dump hass
    '';
    cleanupCommand = "rm -f /var/backup/hass.dump";
  };
  # postgres writes the dump here (restic runs as root and can read it anyway).
  systemd.tmpfiles.rules = [ "d /var/backup 0700 postgres postgres -" ];

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
      # Serve Prometheus metrics on /api/prometheus without auth (the endpoint
      # is only reachable on the guest's loopback) and pin the metric prefix so
      # the dashboard/alerts don't depend on the integration's default.
      prometheus = {
        requires_auth = false;
        namespace = "hass";
      };
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

  # HA 2026.9 moved the HTTP config into `.storage/http` and, after the one-time
  # YAML migration, stages a `http:` block from configuration.yaml as a
  # *pending* trial that auto-reverts after 5 minutes unless confirmed in the
  # UI. So the declared `http.use_x_forwarded_for`/`trusted_proxies` never take
  # effect and HA logs "A request from a reverse proxy was received ... not
  # set-up for reverse proxies" behind nginx. Promote the pending config to
  # stable before HA starts; once they match, this is a no-op.
  systemd.services.home-assistant-http-promote = {
    description = "Promote HA's pending HTTP config so the declared one sticks";
    wantedBy = [ "multi-user.target" ];
    before = [ "home-assistant.service" ];
    path = [ pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      store=/var/lib/hass/.storage/http
      [ -f "$store" ] || exit 0
      jq -e '.data.pending != null' "$store" >/dev/null 2>&1 || exit 0
      tmp="$(mktemp)"
      jq '.data.stable = .data.pending | .data.pending = null' "$store" > "$tmp"
      install -m 600 -o hass -g hass "$tmp" "$store"
      rm -f "$tmp"
      echo "promoted pending HTTP config to stable"
    '';
  };

  # Recorder backend, co-located with HA (no dedicated postgres guest). The
  # default dataDir (/var/lib/postgresql/${psqlSchema}) lands on the
  # `home-assistant-postgres` volume, which terraform mounts at
  # /var/lib/postgresql - otherwise a container recreate drops the history.
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

  # Recorder DB metrics for the PostgreSQL dashboard. Local peer auth as the
  # postgres superuser; the exporter listens on loopback only and the guest's
  # Alloy scrapes it.
  services.prometheus.exporters.postgres = {
    enable = true;
    listenAddress = "127.0.0.1";
    runAsLocalSuperUser = true;
  };

  # HA and its recorder (the co-located PostgreSQL above) start together with
  # the `home-assistant` target.

  # `.dev` is HSTS-preloaded, so the UI must be HTTPS. nginx terminates TLS on
  # :443 (and serves the http-01 challenge on :80), proxying to HA on loopback.
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.${config.local.domain}:8443/acme/internal/directory";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."home-assistant.${config.local.domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8123";
        proxyWebsockets = true;
      };
    };
  };

  # Application metrics for the Home Assistant dashboard: the prometheus
  # integration above serves them on /api/prometheus; the Alloy agent scrapes
  # loopback and remote-writes to the monitoring workload. Entity metrics carry
  # the `hass_` prefix set by the namespace.
  environment.etc."alloy/home-assistant.alloy".text = ''
    prometheus.scrape "home_assistant" {
      targets      = [{ __address__ = "127.0.0.1:8123" }]
      metrics_path = "/api/prometheus"
      job_name     = "home-assistant"
      forward_to   = [prometheus.relabel.host.receiver]
    }
  '';

  environment.etc."alloy/postgres.alloy".text = ''
    prometheus.scrape "postgres" {
      targets    = [{ __address__ = "127.0.0.1:9187" }]
      job_name   = "postgres"
      forward_to = [prometheus.relabel.host.receiver]
    }
  '';

  # nginx (80 for the ACME challenge, 443 for the UI) and SSH - only on the
  # private backplane. HomeKit is also allowed here because HA advertises the
  # default-route address (eth0) first; eth1 additionally provides the direct
  # LAN path and the mDNS discovery.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
    homekitPort
  ];

  # The LAN NIC exposes only what the HomeKit bridge needs: the HAP port and
  # mDNS. SSH and the UI stay on eth0.
  networking.firewall.interfaces.eth1 = lib.mkIf config.local.lan.enable {
    allowedTCPPorts = [ homekitPort ];
    allowedUDPPorts = [ 5353 ];
  };

  system.stateVersion = "26.05";
}
