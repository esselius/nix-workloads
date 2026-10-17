{
  modulesPath,
  config,
  pkgs,
  ...
}:
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "kanidm";
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

  # Back up the identity database (users, groups, oauth2 clients).
  local.backup.paths = [ "/var/lib/kanidm" ];

  # Kanidm mandates TLS on every connection, so it serves HTTPS itself with a
  # cert from the internal step-ca. Trust the Esselius root to talk to step-ca
  # (and so clients trust the issued cert).
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.${config.local.domain}:8443/acme/internal/directory";
    };
    # http-01 via lego's standalone server on :80 (Kanidm itself only serves
    # :8443). group=kanidm so the daemon can read the cert; restart it on renew.
    certs."idm.${config.local.domain}" = {
      listenHTTP = ":80";
      group = "kanidm";
      reloadServices = [ "kanidm.service" ];
    };
  };

  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/kanidm.yaml;
    secrets = {
      kanidm_idm_admin_password = {
        owner = "kanidm";
        mode = "0400";
      };
      grafana_oidc_secret = {
        owner = "kanidm";
        mode = "0400";
      };
      node_red_oidc_secret = {
        owner = "kanidm";
        mode = "0400";
      };
      oauth2_proxy_secret = {
        owner = "kanidm";
        mode = "0400";
      };
      homepage_oidc_secret = {
        owner = "kanidm";
        mode = "0400";
      };
    };
  };

  services.kanidm = {
    package = pkgs.kanidm_1_11.withSecretProvisioning;

    # Administration is CLI-first (the web UI is end-user only), so install and
    # configure the kanidm client on the guest.
    client = {
      enable = true;
      settings.uri = "https://idm.${config.local.domain}";
    };

    server = {
      enable = true;
      settings = {
        # Serve on :443 so the port-less origin/URLs (https://idm.<site zone>)
        # match; the module grants CAP_NET_BIND_SERVICE.
        bindaddress = "0.0.0.0:443";
        origin = "https://idm.${config.local.domain}";
        # The managed identity realm, which stays `int.esselius.dev` even in dev
        # (a restored database owns those identities); only the URL uses the
        # site zone.
        domain = config.local.realm;
        tls_chain = "/var/lib/acme/idm.${config.local.domain}/fullchain.pem";
        tls_key = "/var/lib/acme/idm.${config.local.domain}/key.pem";
      };
    };

    provision = {
      enable = true;
      instanceUrl = "https://idm.${config.local.domain}";
      # First boot serves the acme self-signed placeholder until the step-ca
      # order lands; don't fail the provisioning health-check on that.
      acceptInvalidCerts = true;
      idmAdminPasswordFile = config.sops.secrets.kanidm_idm_admin_password.path;

      groups = {
        grafana_admins = { };
        grafana_users = { };
        # Shared "may sign in to homelab apps" group (Node-RED, oauth2-proxy).
        homelab_users = { };
      };

      persons.peter = {
        displayName = "Peter Esselius";
        mailAddresses = [ "pepp@me.com" ];
        groups = [
          "grafana_admins"
          "grafana_users"
          "homelab_users"
        ];
      };

      systems.oauth2.grafana = {
        displayName = "Grafana";
        originUrl = "https://monitoring.${config.local.domain}/login/generic_oauth";
        originLanding = "https://monitoring.${config.local.domain}/";
        basicSecretFile = config.sops.secrets.grafana_oidc_secret.path;
        scopeMaps.grafana_users = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
        # Expose a `grafana_role` claim from group membership; Grafana maps it
        # to an org role via role_attribute_path.
        claimMaps.grafana_role = {
          joinType = "array";
          valuesByGroup = {
            grafana_admins = [ "GrafanaAdmin" ];
            grafana_users = [ "Viewer" ];
          };
        };
      };

      systems.oauth2.node-red = {
        displayName = "Node-RED";
        originUrl = "https://node-red.${config.local.domain}/auth/strategy/callback/";
        originLanding = "https://node-red.${config.local.domain}/";
        basicSecretFile = config.sops.secrets.node_red_oidc_secret.path;
        # passport-openidconnect doesn't send a PKCE challenge; Kanidm enforces
        # it by default.
        allowInsecureClientDisablePkce = true;
        scopeMaps.homelab_users = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };

      systems.oauth2.oauth2-proxy = {
        displayName = "Zigbee2MQTT";
        originUrl = "https://zigbee2mqtt.${config.local.domain}/oauth2/callback";
        originLanding = "https://zigbee2mqtt.${config.local.domain}/";
        basicSecretFile = config.sops.secrets.oauth2_proxy_secret.path;
        scopeMaps.homelab_users = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };

      systems.oauth2.homepage = {
        displayName = "Homepage";
        originUrl = "https://homepage.${config.local.domain}/oauth2/callback";
        originLanding = "https://homepage.${config.local.domain}/";
        basicSecretFile = config.sops.secrets.homepage_oidc_secret.path;
        scopeMaps.homelab_users = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };
    };
  };

  # kanidm bind-mounts its TLS cert, so the cert must exist before it starts -
  # otherwise the mount namespace fails ("No such file or directory"). Wait for
  # the acme self-signed service, which creates the file immediately; the real
  # cert from step-ca then replaces it (reloadServices restarts kanidm).
  systemd.services.kanidm = {
    after = [ "acme-idm.${config.local.domain}.service" ];
    wants = [ "acme-idm.${config.local.domain}.service" ];
  };

  # :80 for the ACME challenge, :443 for Kanidm itself, plus SSH - only on the
  # private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
