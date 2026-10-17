# The single source of truth for *where* each workload runs and *where* it is
# addressed. Two dimensions, kept deliberately separate:
#
#   * an "env" is a logical environment - one DNS zone and one address space
#     (the homelab on the Pi, or `dev` on a local incus VM);
#   * within an env, "hosts" are the incus servers and "placement" maps a
#     service to a host.
#
# Workloads never learn which host runs a dependency: they reference names
# (`mosquitto.${config.local.domain}`) and coredns resolves them to wherever the
# service is placed. Moving a service between hosts is therefore a change to
# `placement` (and its A record), never to the workloads themselves.
#
# An env's `zone` is a *flat* namespace: there is no per-host suffix. Two hosts
# in one env simply occupy different subnets, and a service has one name.
let
  envs = {
    homelab = {
      zone = "int.esselius.dev";
      # Kanidm's identity realm, independent of where its URL lives.
      realm = "int.esselius.dev";
      defaultHost = "rpi5-8gb";
      hosts = {
        rpi5-8gb = {
          remote = "rpi5-8gb";
          subnet = "10.43.0";
          bridge = "incusbr-vpn";
          pool = "default";
        };
        # Bring rpi5-4gb online by adding a host here with its own subnet, then
        # setting `placement` entries below. Same zone, same service names.
        #   rpi5-4gb = { remote = "rpi5-4gb"; subnet = "10.44.0"; bridge = "incusbr-vpn"; pool = "default"; };
      };
      placement = { };
    };

    dev = {
      zone = "dev.int.esselius.dev";
      realm = "int.esselius.dev";
      defaultHost = "colima";
      hosts = {
        colima = {
          remote = "colima";
          subnet = "10.60.0";
          bridge = "incusbr-vpn";
          pool = "default";
          # `colima status --profile <colimaProfile> --json`.
          colimaProfile = "dev";
        };
        # A second VM for cross-host/failure tests: add it and set `placement`.
        #   colima-b = { remote = "colima-b"; subnet = "10.61.0"; bridge = "incusbr-vpn"; pool = "default"; colimaProfile = "dev-b"; };
      };
      placement = { };
    };
  };

  # Keyed by directory name under terraform/ and guests/. `dns` lists the names
  # that resolve to the service (aliases included); `[]` means "no A record".
  services = {
    example = {
      ip = 10;
      dns = [ ];
    };
    mosquitto = {
      ip = 11;
      dns = [ "mosquitto" ];
    };
    monitoring = {
      ip = 12;
      dns = [ "monitoring" ];
    };
    kanidm = {
      ip = 13;
      dns = [ "idm" ];
    };
    coredns = {
      ip = 14;
      dns = [
        "coredns"
        "ns1"
      ];
    };
    step-ca = {
      ip = 15;
      dns = [ "step-ca" ];
    };
    node-red = {
      ip = 16;
      dns = [ "node-red" ];
    };
    zigbee2mqtt = {
      ip = 17;
      dns = [ "zigbee2mqtt" ];
    };
    backup = {
      ip = 18;
      dns = [ "backup" ];
    };
    home-assistant = {
      ip = 19;
      dns = [ "home-assistant" ];
    };
    attic = {
      ip = 20;
      dns = [ "cache" ];
    };
    homepage = {
      ip = 21;
      dns = [ "homepage" ];
    };
  };

  hostFor = env: service: envs.${env}.placement.${service} or envs.${env}.defaultHost;
in
{
  inherit envs services hostFor;

  # The env's DNS zone (also the guests' `local.domain`).
  zoneFor = env: envs.${env}.zone;

  # IPv4 address of a service in an env, from its host's subnet + last octet.
  ipFor =
    env: service:
    "${envs.${env}.hosts.${hostFor env service}.subnet}.${toString services.${service}.ip}";
}
