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
          # Colima's incus remote for a profile named `<profile>` is
          # `colima-<profile>` (the default profile is just `colima`) - read it
          # from `incus remote list` after `colima start --profile dev`.
          remote = "colima-dev";
          subnet = "10.60.0";
          bridge = "incusbr-vpn";
          pool = "default";
          # `colima status --profile <colimaProfile> --json`.
          colimaProfile = "dev";
        };
        # A second VM for cross-host/failure tests: add it and set `placement`.
        #   colima-b = { remote = "colima-dev-b"; subnet = "10.61.0"; bridge = "incusbr-vpn"; pool = "default"; colimaProfile = "dev-b"; };
      };
      placement = { };
    };
  };

  # Keyed by directory name under terraform/ and guests/. `dns` lists the names
  # that resolve to the service (aliases included); `[]` means "no A record".
  # `https = true` marks services the dev `edge` ingress should route TLS to.
  services = {
    edge = {
      ip = 9;
      dns = [ ];
    };
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
      https = true;
    };
    kanidm = {
      ip = 13;
      dns = [ "idm" ];
      https = true;
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
      https = true;
    };
    zigbee2mqtt = {
      ip = 17;
      dns = [ "zigbee2mqtt" ];
      https = true;
    };
    backup = {
      ip = 18;
      dns = [ "backup" ];
    };
    home-assistant = {
      ip = 19;
      dns = [ "home-assistant" ];
      https = true;
    };
    attic = {
      ip = 20;
      dns = [ "cache" ];
      https = true;
    };
    homepage = {
      ip = 21;
      dns = [ "homepage" ];
      https = true;
    };
  };

  # Per-workload container memory allocation, keyed by service. `limit` is the
  # hard cgroup max the instance may use (page cache included, so it can be
  # above anonymous usage); `swap` allows that much zram-backed swap on top;
  # `oomPriority` is the Incus OOM adjustment (-1000..1000). The shared
  # `container` profile remains the fallback for anything not listed here.
  memory = {
    edge = {
      limit = "256MiB";
      swap = "64MiB";
      oomPriority = "0";
    };
    example = {
      limit = "256MiB";
      swap = "64MiB";
      oomPriority = "0";
    };
    mosquitto = {
      limit = "448MiB";
      swap = "64MiB";
      oomPriority = "-300";
    };
    monitoring = {
      limit = "1792MiB";
      swap = "256MiB";
      oomPriority = "100";
    };
    kanidm = {
      limit = "320MiB";
      swap = "128MiB";
      oomPriority = "-200";
    };
    coredns = {
      limit = "320MiB";
      swap = "64MiB";
      oomPriority = "-200";
    };
    step-ca = {
      limit = "512MiB";
      swap = "128MiB";
      oomPriority = "-200";
    };
    node-red = {
      limit = "384MiB";
      swap = "128MiB";
      oomPriority = "0";
    };
    zigbee2mqtt = {
      limit = "1024MiB";
      swap = "128MiB";
      oomPriority = "-200";
    };
    backup = {
      limit = "448MiB";
      swap = "64MiB";
      oomPriority = "300";
    };
    home-assistant = {
      limit = "1280MiB";
      swap = "256MiB";
      oomPriority = "-200";
    };
    attic = {
      limit = "384MiB";
      swap = "128MiB";
      oomPriority = "300";
    };
    homepage = {
      limit = "384MiB";
      swap = "128MiB";
      oomPriority = "0";
    };
  };

  # Central-scrape metadata for guests in `light` monitoring mode: `node`
  # enables the guest's node_exporter target, `app` is the guest's application
  # exporter (`port` plus optional `path` and `job`), `restic` is the
  # restic-exporter on :9753. Services not listed here keep the per-guest
  # Alloy and its local scrapes.
  metrics = {
    attic = {
      node = true;
    };
    backup = {
      node = true;
    };
    coredns = {
      node = true;
    };
    homepage = {
      node = true;
    };
    kanidm = {
      node = true;
      restic = true;
    };
    mosquitto = {
      node = true;
      app = {
        port = 9234;
        job = "mosquitto";
      };
    };
    node-red = {
      node = true;
    };
    step-ca = {
      node = true;
      restic = true;
    };
    zigbee2mqtt = {
      node = true;
      restic = true;
      app = {
        port = 9000;
        job = "zigbee2mqtt";
      };
    };
  };

  hostFor = env: service: envs.${env}.placement.${service} or envs.${env}.defaultHost;
in
{
  inherit
    envs
    services
    memory
    metrics
    hostFor
    ;

  # The env's DNS zone (also the guests' `local.domain`).
  zoneFor = env: envs.${env}.zone;

  # IPv4 address of a service in an env, from its host's subnet + last octet.
  ipFor =
    env: service:
    "${envs.${env}.hosts.${hostFor env service}.subnet}.${toString services.${service}.ip}";
}
