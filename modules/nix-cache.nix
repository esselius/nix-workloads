{
  config,
  lib,
  ...
}:
let
  cfg = config.local.cache;
in
{
  # The shared Attic cache (the `attic` workload) plus the external Cachix
  # fallback. Additive: extra-substituters keeps cache.nixos.org in place, so
  # these only add sources. The Attic URL and signing key come from the active
  # profile (see modules/local.nix); the Cachix key is the same one the hosts
  # already trust.
  nix.settings = {
    # `dev` has no Attic (url = ""), but Cachix is still available.
    extra-substituters =
      lib.optional (cfg.url != "") cfg.url ++ lib.optional (cfg.cachixUrl != "") cfg.cachixUrl;
    extra-trusted-public-keys =
      lib.optional (cfg.publicKey != "" && cfg.url != "") cfg.publicKey
      ++ lib.optional (cfg.cachixPublicKey != "" && cfg.cachixUrl != "") cfg.cachixPublicKey;
  };
}
