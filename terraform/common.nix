{ lib, ... }:
{
  # The managed incus bridge workloads attach to for WireGuard-reachable
  # addressing. Single source of truth for the workload modules; must match
  # nix-homelab-hosts `local.incus.network.vpn.bridge`.
  options.local.vpnBridge = lib.mkOption {
    type = lib.types.str;
    default = "incusbr-vpn";
    description = "Managed incus bridge that workloads attach to.";
  };

  config = {
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
      generate_client_certificates = true;
      accept_remote_certificate = true;
      default_remote = "rpi5-8gb";
      remote = [
        {
          name = "rpi5-8gb";
          address = "https://rpi5-8gb.x.esselius.dev:8443";
          authentication_type = "tls";
        }
      ];
    };
  };
}
