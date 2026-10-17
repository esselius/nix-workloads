{ lib, config, ... }:
let
  inv = import ../inventory.nix;
  envCfg = inv.envs.${config.local.env};
  host = envCfg.hosts.${envCfg.defaultHost};
in
{
  # Which env this terranix config targets. The homelab is the default; a
  # `terraform/envs/dev.nix` module sets `local.env = "dev"`. Everything
  # below (bridge, pool, incus remote, LAN NIC) is derived from the inventory
  # so a workload's terraform never encodes a physical host.
  options.local.env = lib.mkOption {
    type = lib.types.str;
    default = "homelab";
    description = "Environment (key into inventory.nix).";
  };

  # Managed incus bridge workloads attach to.
  options.local.vpnBridge = lib.mkOption {
    type = lib.types.str;
    description = "Managed incus bridge that workloads attach to.";
  };

  # Physical uplink the macvlan `eth1` children are created on. Board-specific:
  # the Pi 5 vendor kernel/DTB names the wired NIC `end0`, not `eth0`.
  options.local.lanParent = lib.mkOption {
    type = lib.types.str;
    default = "end0";
    description = "Host NIC that LAN-reachable macvlan interfaces are created on.";
  };

  # incus storage pool backing workload data volumes (persistent state).
  options.local.storagePool = lib.mkOption {
    type = lib.types.str;
    description = "incus storage pool for workload data volumes.";
  };

  # The macvlan `eth1` LAN NIC some workloads carry (homelab only).
  options.local.lan.enable = lib.mkOption {
    type = lib.types.bool;
    description = "Attach the macvlan eth1 LAN NIC.";
  };

  # Which incus server OpenTofu drives, from the env's host in the inventory.
  options.local.incus = {
    defaultRemote = lib.mkOption {
      type = lib.types.str;
      description = "incus remote the provider uses by default.";
    };
    remote = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Inline remotes declared to the provider (empty = use ~/.config/incus).";
    };
    generateClientCertificates = lib.mkOption {
      type = lib.types.bool;
    };
    acceptRemoteCertificate = lib.mkOption {
      type = lib.types.bool;
    };
  };

  config = {
    local.vpnBridge = lib.mkDefault host.bridge;
    local.storagePool = lib.mkDefault host.pool;
    local.lan.enable = lib.mkDefault (config.local.env == "homelab");

    local.incus.defaultRemote = lib.mkDefault host.remote;
    # The homelab remote is declared inline (the Mac has no local incus daemon);
    # `dev` uses whatever the local `colima` remote is configured to be.
    local.incus.remote = lib.mkDefault (
      if config.local.env == "homelab" then
        [
          {
            name = "rpi5-8gb";
            address = "https://rpi5-8gb.x.esselius.dev:8443";
            authentication_type = "tls";
          }
        ]
      else
        [ ]
    );
    local.incus.generateClientCertificates = lib.mkDefault (config.local.env == "homelab");
    local.incus.acceptRemoteCertificate = lib.mkDefault true;

    terraform.required_providers.incus = {
      source = "lxc/incus";
      version = "~> 1.2";
    };

    # The Mac is the OpenTofu client. It has no incus daemon of its own, so the
    # remote is declared inline (rather than relying on an out-of-band
    # ~/.config/incus/config.yml entry). The provider reuses/generates the
    # client certificate in ~/.config/incus and accepts the server certificate
    # on first contact.
    #
    # Prerequisite: the Mac's client cert must be trusted by the host. See the
    # README ("Prerequisites") - the host's local.incus.tls.clientCertificates
    # lives in github.com/esselius/nix-homelab-hosts.
    provider.incus = {
      generate_client_certificates = config.local.incus.generateClientCertificates;
      accept_remote_certificate = config.local.incus.acceptRemoteCertificate;
      default_remote = config.local.incus.defaultRemote;
      remote = config.local.incus.remote;
    };
  };
}
