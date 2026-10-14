{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
in
{
  # Shared, profile-selectable knobs. Defaults describe the homelab (the Pi
  # hosts); a local env (e.g. an incus VM on the Mac) can override them by
  # setting `local.*` in its own module. Guests read these instead of
  # hard-coding `int.esselius.dev` / the Esselius CA / the Attic cache.
  options.local = {
    domain = mkOption {
      type = types.str;
      default = "int.esselius.dev";
      description = "DNS suffix for workload hostnames (vhosts, coredns zone, ACME SANs).";
    };

    caFiles = mkOption {
      type = types.listOf types.path;
      default = [ ../certs/root_ca.crt ];
      description = "CA certificate files trusted by every guest.";
    };

    acmeServer = mkOption {
      type = types.str;
      default = "https://step-ca.int.esselius.dev:8443/acme/internal/directory";
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
        default = "https://cache.int.esselius.dev/homelab";
      };
      publicKey = mkOption {
        type = types.str;
        default = "homelab:pFO/rlooR8VpYf/qzCPDwxIxynbX5lwtSP0CmBZbAdw=";
      };
    };

    # The macvlan `eth1` LAN NIC some workloads carry.
    lan = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      address = mkOption {
        type = types.str;
        default = "192.168.50.150/24";
      };
    };
  };

  config.security.pki.certificateFiles = config.local.caFiles;
}
