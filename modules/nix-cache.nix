{
  lib,
  ...
}:
let
  # The shared Attic cache (the `attic` workload). Additive: extra-substituters
  # keeps cache.nixos.org in place, so this only adds a source.
  cacheUrl = "https://cache.int.esselius.dev/homelab";

  # The cache's narinfo signing key is generated when the cache is *created*, so
  # it can't be known here until the one-time bootstrap. Read it with
  #
  #   attic cache info homelab   ->   Public Key: homelab:<base64>
  #
  # and paste the whole `homelab:<base64>` string below. Until it is set the
  # substituter is listed but untrusted, so nix simply falls back to receiving
  # paths over SSH (no harm). See the README's build-cache section.
  cachePublicKey = "homelab:pFO/rlooR8VpYf/qzCPDwxIxynbX5lwtSP0CmBZbAdw=";
in
{
  nix.settings = {
    extra-substituters = [ cacheUrl ];
    extra-trusted-public-keys = lib.optional (cachePublicKey != null) cachePublicKey;
  };

  # The cache is served over HTTPS with a cert from the internal step-ca, not a
  # public CA. Without this every guest's nix-daemon fails TLS verification while
  # substituting (unable to get local issuer certificate) and nix-copy-closure
  # silently falls back to copying the closure over SSH. Trusting the internal
  # root in the system PKI also makes the daemon use it (NixOS passes the bundle
  # to nix-daemon as CURL_CA_BUNDLE), so substitution actually works.
  security.pki.certificateFiles = [ ../certs/root_ca.crt ];
}
