{
  modulesPath,
  config,
  pkgs,
  ...
}:
let
  # passport-openidconnect (Node-RED's admin OIDC strategy) isn't in nixpkgs;
  # the node2nix package is vendored under pkgs/. Its generated default pins
  # nodejs_18, which 26.05 no longer ships, so override to nodejs_22.
  passportOpenidconnect =
    (pkgs.callPackage ../../pkgs/passport-openidconnect { nodejs = pkgs.nodejs_22; }).package;
in
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  local.monitoring.mode = "light";

  networking = {
    hostName = "node-red";
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

  # The OIDC client secret and the credential secret are read at Node-RED
  # startup from sops-installed files (see settings.js), never the Nix store.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/node-red.yaml;
    secrets = {
      node_red_oidc_secret = {
        owner = "node-red";
        mode = "0400";
      };
      node_red_credential_secret = {
        owner = "node-red";
        mode = "0400";
      };
    };
  };

  # Back up the Node-RED state that lives under the volume mounted at
  # /var/lib/node-red: flows.json, credentials (encrypted with the sops
  # credential secret), context and the palette (node_modules) the flows need to
  # load. The npm download cache is regenerable, so leave it out.
  local.backup = {
    paths = [ "/var/lib/node-red" ];
    exclude = [ "/var/lib/node-red/.npm/_cacache" ];
  };

  # Node-RED's OIDC strategy lives in passport-openidconnect; expose it via
  # NODE_PATH and point the settings at the sops files.
  systemd.services.node-red.environment = {
    NODE_PATH = "${passportOpenidconnect}/lib/node_modules";
    NODE_RED_OIDC_SECRET_FILE = config.sops.secrets.node_red_oidc_secret.path;
    NODE_RED_CREDENTIAL_SECRET_FILE = config.sops.secrets.node_red_credential_secret.path;
    # Env-derived OIDC URLs read by settings.js (Kanidm issuer + callback).
    NODE_RED_IDM_URL = "https://idm.${config.local.domain}";
    NODE_RED_PUBLIC_URL = "https://node-red.${config.local.domain}";
  };

  services.node-red = {
    enable = true;
    # Palette installs (e.g. node-red-contrib-zigbee2mqtt) need npm + a compiler.
    withNpmAndGcc = true;
    port = 1880;
    openFirewall = false;
    configFile = ./settings.js;
  };

  # `.dev` is HSTS-preloaded, so the editor must be HTTPS. nginx terminates TLS
  # on :443 (and serves the http-01 challenge on :80), proxying to Node-RED on
  # loopback with websocket support (the editor's live updates).
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
    virtualHosts."node-red.${config.local.domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.node-red.port}";
        proxyWebsockets = true;
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the editor) and SSH - only on the
  # private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
