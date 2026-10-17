{
  lib,
  ...
}:
{
  # Every guest is a remotely-managed incus container: it never builds
  # (nix.settings.max-jobs = 0), never installs or bootstraps NixOS, and is
  # always rebuilt from the outside with `task deploy` / `nixos-rebuild
  # --target-host`. So drop the parts of a stock NixOS system that only exist to
  # build/install/reconfigure NixOS *locally*, or to prettify an interactive
  # shell. The whole fleet substitutes from one Attic cache, so this both shrinks
  # each guest closure and reduces what the cache must hold.
  #
  # Measured on the `mosquitto` guest: ~1.4 GiB -> ~1.0 GiB.
  config = {
    # /etc/nix/registry.json otherwise pins the full nixpkgs source (~197 MiB)
    # into the closure so `nix run nixpkgs#...` is reproducible. These guests
    # never run nix at all, so drop it (and the matching NIX_PATH pin).
    nixpkgs.flake.setFlakeRegistry = false;
    nixpkgs.flake.setNixPath = false;

    # The bundled NixOS channel (another copy of the nixpkgs source, ~197 MiB,
    # plus a nix-channel-init service) exists so a fresh install can run
    # nixos-install/nixos-rebuild offline. Nothing here ever installs or
    # bootstraps NixOS, so drop the channel and the nix-channel machinery.
    system.installer.channel.enable = false;
    nix.channel.enable = false;

    # Drops nixos-rebuild/-generate-config/-install/-enter/... and, with them,
    # the Python interpreter nixos-rebuild-ng drags in (~131 MiB).
    system.disableInstallerTools = true;

    # The interactive-convenience defaults (perl, rsync, strace).
    environment.defaultPackages = lib.mkForce [ ];

    # man pages, the NixOS manual, info pages.
    documentation.enable = false;
    programs.command-not-found.enable = false;

    # Headless, non-interactive, mount-free containers: drop the font stack
    # (nothing renders text), FUSE (nothing mounts userspace filesystems here),
    # and nano (config is declarative, edited from outside via `nixos-rebuild`).
    # Each is on by default and none is referenced by these guests. `logrotate`
    # is deliberately KEPT: the nginx guests (home-assistant, node-red,
    # homepage, kanidm, monitoring, ...) rely on it to rotate /var/log/nginx, and
    # `security.sudo` is kept as the interactive break-glass.
    fonts.fontconfig.enable = false;
    programs.fuse.enable = false;
    programs.nano.enable = false;
  };
}
