{
  config,
  lib,
  ...
}:
let
  cfg = config.local.cache;
in
{
  # The shared Attic cache (the `attic` workload). Additive: extra-substituters
  # keeps cache.nixos.org in place, so this only adds a source. The URL and
  # signing key come from the active profile (see modules/local.nix) - the
  # public key is set once via `attic cache info homelab` after the cache is
  # created (README "One-time bootstrap").
  nix.settings = {
    extra-substituters = [ cfg.url ];
    extra-trusted-public-keys = lib.optional (cfg.publicKey != "") cfg.publicKey;
  };
}
