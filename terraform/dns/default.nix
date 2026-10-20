{ lib, config, ... }:
let
  inv = import ../../inventory.nix;
  env = config.local.env;
  zone = inv.zoneFor env;
  envCfg = inv.envs.${env};
  host = envCfg.hosts.${envCfg.defaultHost};
  ns1Address = host.dnsAddress or null;

  dnsServices = lib.filterAttrs (_: svc: svc.dns != [ ]) inv.services;

  # Canonical records are written explicitly, not left to Incus's generated
  # instance records: with more than one cluster the zone must be complete
  # everywhere, and auto-records only cover the local host.
  canonical = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "a-${name}" {
      name = name;
      zone = zone;
      depends_on = [ "incus_network_zone.int" ];
      entry = [
        {
          type = "A";
          value = inv.ipFor env name;
          ttl = 300;
        }
      ];
    }
  ) dnsServices;

  # Flat aliases point at the canonical name; ns1 is the host resolver.
  aliases = lib.concatMapAttrs (
    name: svc:
    lib.listToAttrs (
      map (
        alias:
        lib.nameValuePair "cname-${alias}" {
          name = alias;
          zone = zone;
          depends_on = [ "incus_network_zone.int" ];
          entry = [
            {
              type = "CNAME";
              value = "${name}.${zone}.";
              ttl = 300;
            }
          ];
        }
      ) (lib.filter (alias: alias != name && alias != "ns1") svc.dns)
    )
  ) dnsServices;
in
{
  resource.incus_network_zone.int = {
    name = zone;
    config = {
      "dns.contact" = "hostmaster@${zone}";
      "dns.nameservers" = "ns1.${zone}";
      "peers.unbound.address" = "127.0.0.1";
    };
  };

  # The Incus provider only accepts A/AAAA/CNAME/TXT entries. SRV is therefore
  # served by the host Unbound's static local-data (local.dns.srv), not by an
  # Incus custom record.
  resource.incus_network_zone_record =
    canonical
    // aliases
    // lib.optionalAttrs (ns1Address != null) {
      ns1 = {
        name = "ns1";
        zone = zone;
        depends_on = [ "incus_network_zone.int" ];
        entry = [
          {
            type = "A";
            value = ns1Address;
            ttl = 300;
          }
        ];
      };
    };
}
