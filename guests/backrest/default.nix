{
  modulesPath,
  config,
  lib,
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
    hostName = "backrest";
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

  # The oauth2-proxy OIDC client secret (the Kanidm `backrest` client) and cookie
  # secret are rendered into an EnvironmentFile, never the Nix store.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/kanidm.yaml;
    secrets = {
      backrest_oidc_secret = { };
      backrest_cookie_secret = { };
    };
    templates."oauth2-proxy.env" = {
      owner = "oauth2-proxy";
      group = "oauth2-proxy";
      restartUnits = [ "oauth2-proxy.service" ];
      content = ''
        OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.backrest_oidc_secret}
        OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.backrest_cookie_secret}
      '';
    };
  };

  # Backrest wraps the restic CLI with a web UI for browsing/restoring snapshots
  # (and, opt-in, scheduling). Bound to loopback; nginx + oauth2-proxy front it.
  # Config (admin account, repo list) and the operation log persist on the
  # /var/lib/backrest volume. The admin account is created on first visit.
  systemd.services.backrest = {
    description = "Backrest (web UI for restic)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      BACKREST_PORT = "127.0.0.1:9898";
      BACKREST_CONFIG = "/var/lib/backrest/config.json";
      BACKREST_DATA = "/var/lib/backrest/data";
      BACKREST_RESTIC_COMMAND = "${pkgs.restic}/bin/restic";
      XDG_CACHE_HOME = "/var/cache/backrest";
    };
    serviceConfig = {
      ExecStart = "${pkgs.backrest}/bin/backrest";
      CacheDirectory = "backrest";
      Restart = "on-failure";
    };
  };

  # `.dev` is HSTS-preloaded, so the UI must be HTTPS. nginx terminates TLS on
  # :443 (and serves the http-01 challenge on :80); oauth2-proxy (Kanidm) gates
  # the dashboard, reverse-proxying to it on loopback.
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.int.esselius.dev:8443/acme/internal/directory";
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://idm.int.esselius.dev/oauth2/openid/backrest";
    clientID = "backrest";
    email.domains = [ "*" ];
    redirectURL = "https://backrest.int.esselius.dev/oauth2/callback";
    upstream = [ "http://127.0.0.1:9898" ];
    reverseProxy = true;
    setXauthrequest = true;
    extraConfig.code-challenge-method = "S256";
    keyFile = config.sops.templates."oauth2-proxy.env".path;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."backrest.int.esselius.dev" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:4180";
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
