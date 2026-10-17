{
  config,
  lib,
  ...
}:
{
  # In `dev`, guests decrypt the committed secrets with the Mac's age identity
  # (pushed to /etc/nix-workloads/dev-age.key by `task deploy`) instead of their
  # own per-guest host key, so no secret needs re-keying or a gitignored overlay.
  # The homelab keeps per-guest host keys.
  config = lib.mkIf (config.local.env != "homelab") {
    sops.age.keyFile = lib.mkForce "/etc/nix-workloads/dev-age.key";
    sops.age.sshKeyPaths = lib.mkForce [ ];
  };
}
