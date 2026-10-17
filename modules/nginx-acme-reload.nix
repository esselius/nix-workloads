{
  config,
  lib,
  pkgs,
  ...
}:
let
  # nixpkgs' acme module reloads `reloadServices` only when its `renewed` marker
  # exists, so a cert that is issued *after* nginx first started (the common
  # first-deploy case: the self-signed placeholder is served while the order is
  # in flight) is not picked up until nginx happens to restart. Watch each ACME
  # cert directory and reload nginx whenever it changes.
  certNames = lib.unique (
    lib.mapAttrsToList (name: vh: if vh.useACMEHost != null then vh.useACMEHost else name) (
      lib.filterAttrs (_: vh: vh.enableACME || vh.useACMEHost != null) config.services.nginx.virtualHosts
    )
  );
in
{
  config = lib.mkIf (config.services.nginx.enable && certNames != [ ]) {
    systemd.paths.nginx-acme-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = map (c: "/var/lib/acme/${c}") certNames;
    };
    systemd.services.nginx-acme-reload = {
      description = "Reload nginx when an ACME certificate changes";
      serviceConfig = {
        Type = "oneshot";
        # `nginx -s reload` does not re-read the certificate here (the placeholder
        # stays in memory), so restart the unit.
        ExecStart = "${pkgs.systemd}/bin/systemctl restart nginx.service";
      };
    };
  };
}
