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
  # hosts); `profiles/local.nix` overrides them for a local Colima run. Guests
  # read these instead of hard-coding `int.esselius.dev` / the Esselius CA / the
  # Attic cache, so one profile switch retargets the whole stack.
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

    # Directory the guests' sops files live in. The local profile points this at
    # a gitignored overlay (secrets/local/) re-encrypted for the local guests, so
    # onboarding a Colima guest never rewrites the committed secrets.
    sopsDir = mkOption {
      type = types.path;
      default = ../secrets;
    };

    # Static TLS material for local runs (null = issue via ACME).
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

    # The macvlan `eth1` LAN NIC some workloads carry. Off for local runs
    # (there is no physical LAN uplink inside the VM).
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
