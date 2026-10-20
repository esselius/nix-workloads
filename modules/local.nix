{
  lib,
  config,
  env ? "homelab",
  ...
}:
let
  inherit (lib) mkOption types;
  inv = import ../inventory.nix;
  envCfg = inv.envs.${env};
  zone = envCfg.zone;
in
{
  # Shared, env-selectable knobs. Defaults come from `inventory.nix` for the
  # active `env` (homelab = the Pi; dev = a local incus VM), so a guest reads
  # `config.local.*` and never hard-codes a domain, CA, cache or LAN detail.
  # The `env` is supplied by the flake (`nixosConfigurations.<name>` is the
  # homelab; `<name>-dev` is the local testbed).
  options.local = {
    env = mkOption {
      type = types.str;
      default = env;
      description = "Environment this system is built for (key into inventory.nix).";
    };

    domain = mkOption {
      type = types.str;
      default = zone;
      description = "DNS suffix for workload hostnames (vhosts, network zone, ACME SANs).";
    };

    # The identity realm is deliberately separate from `domain`: a dev Kanidm
    # serves `idm.<dev zone>` but still owns the production `int.esselius.dev`
    # identities that were restored from backup.
    realm = mkOption {
      type = types.str;
      default = envCfg.realm;
      description = "Identity realm (Kanidm managed domain, user suffixes).";
    };

    # The env's internal resolver, used to advertise DNS to guests.
    dnsAddress = mkOption {
      type = types.str;
      default = envCfg.hosts.${envCfg.defaultHost}.dnsAddress or "127.0.0.1";
      description = "Internal host Unbound address for the env.";
    };

    caFiles = mkOption {
      type = types.listOf types.path;
      default = [ ../certs/root_ca.crt ];
      description = "CA certificate files trusted by every guest.";
    };

    acmeServer = mkOption {
      type = types.str;
      default = "https://step-ca.${zone}:8443/acme/internal/directory";
      description = "ACME directory guests issue their TLS certs from.";
    };

    acmeEmail = mkOption {
      type = types.str;
      default = "acme@esselius.dev";
    };

    # Static TLS material (null = issue via ACME).
    tls = {
      cert = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
      key = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };

    cache = {
      url = mkOption {
        type = types.str;
        # Only the homelab has an Attic cache; `dev` copies closures instead.
        default = if env == "homelab" then "https://cache.${zone}/homelab" else "";
        description = "Attic substituter URL (\"\" = no cache).";
      };
      publicKey = mkOption {
        type = types.str;
        default = "homelab:pFO/rlooR8VpYf/qzCPDwxIxynbX5lwtSP0CmBZbAdw=";
      };
    };

    # The macvlan `eth1` LAN NIC some workloads carry. Absent in `dev` (no
    # physical LAN uplink inside the VM).
    lan = {
      enable = mkOption {
        type = types.bool;
        default = env == "homelab";
      };
      address = mkOption {
        type = types.str;
        default = "192.168.50.150/24";
      };
    };
  };

  config.security.pki.certificateFiles = config.local.caFiles;
}
