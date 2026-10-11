{
  config,
  lib,
  ...
}:
let
  cfg = config.local.lxc;
in
{
  # LXC's distrobuilder generator writes service.d/zzz-lxc-service.conf, which
  # clears LoadCredential=/ImportCredential= for NON-nested containers - an
  # AppArmor-era compatibility shim (upstream assumes the credential/sandbox
  # mounts fail without nesting). On a host without AppArmor the mount works, so
  # the clearing just breaks systemd credentials (e.g. services.mosquitto's
  # passwordFile).
  #
  # Enabling this patches the generator to drop the `LoadCredential=` line,
  # keeping its other fixes. It re-enables LoadCredential for *every* service
  # that declares it, not just yours. Upstream tried the same and reverted it
  # (distrobuilder PR #1003, "broke most of our images" - on AppArmor hosts), so
  # this is opt-in per container. See AGENTS.md.
  options.local.lxc.allowSystemdCredentials = lib.mkEnableOption ''
    systemd credentials (LoadCredential) in this non-nested incus container, by
    stopping LXC's distrobuilder generator from clearing them
  '';

  config = lib.mkIf cfg.allowSystemdCredentials {
    nixpkgs.overlays = [
      (final: prev: {
        distrobuilder = prev.distrobuilder // {
          generator = prev.distrobuilder.generator.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.gnused ];
            postPatch = (old.postPatch or "") + ''
              sed -i 's|echo "LoadCredential="|echo "#LoadCredential="|' distrobuilder/lxc.generator
            '';
          });
        };
      })
    ];
  };
}
