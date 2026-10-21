{
  description = "Smart-home workloads as incus instances on rpi5-8gb (nix-homelab-hosts)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Used to build the pysignalr Home Assistant dependency from its
    # pyproject.toml (see pkgs/pysignalr.nix).
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Home Assistant band-aid: `adama` ran HA from nixpkgs-unstable (2026.9.x),
    # but this repo pins nixos-26.05 (HA 2026.5.x). Copying a newer `.storage` /
    # config onto an older HA is a downgrade, so the `home-assistant` workload
    # overlays only HA (and its Python closure) from this pinned unstable
    # revision, leaving everything else on the 26.05 pin. Drop this input and
    # the overlay once NixOS 26.11 ships HA 2026.9+. See README.
    nixpkgs-ha = {
      url = "github:NixOS/nixpkgs/55ba7f49ef2962b42cbd126522b7df5f95037679";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      nixpkgs-ha,
      terranix,
      sops-nix,
      ...
    }:
    let
      lib = nixpkgs.lib;

      # The HA package (with its own Python closure, e.g. python314Packages)
      # from the pinned unstable revision. Overlaying the single attribute -
      # rather than setting `services.home-assistant.package` - keeps the
      # module's `buildHomeAssistantComponent` and our custom components on the
      # same HA/python, since they resolve `home-assistant` from `pkgs`.
      haPkgs = nixpkgs-ha.legacyPackages.aarch64-linux;
      homeAssistantOverlay = _final: _prev: {
        home-assistant = haPkgs.home-assistant;
      };
      homeAssistantOverlayModule = {
        nixpkgs.overlays = [ homeAssistantOverlay ];
      };

      # Single source of truth: every workload is a sibling directory under
      # guests/ (mirrored by terraform/<name>/). Adding a workload means
      # creating those two directories - there is no list to keep in sync here,
      # in the terranix configs, in nixosConfigurations, or in the checks.
      workloads = builtins.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./guests)
      );

      # The only per-guest deviations from the common shape. Anything not listed
      # imports sops-nix and takes no extra specialArgs.
      guestMeta = {
        example = {
          sops = false;
        };
        # Dev-only TLS SNI ingress; no secrets.
        edge = {
          sops = false;
        };
        home-assistant = {
          sops = true;
          specialArgs = {
            pyproject-nix-lib = inputs.pyproject-nix.lib;
          };
          extraModules = [ homeAssistantOverlayModule ];
        };
      };
      metaFor = name: guestMeta.${name} or { sops = true; };

      # `-dev` variants are the same guest systems built for the local testbed
      # env (see inventory.nix); they share every module and differ only in the
      # `env` specialArg, so components can be trialled locally before a
      # homelab rollout.
      devAttrs = map (name: "${name}-dev") workloads;
      allAttrs = workloads ++ devAttrs;

      # The DNS zone is shared infrastructure, not a guest workload. It still
      # uses the same terranix/tf wrapper, but has no nixosConfiguration.
      infraWorkloads = [ "dns" ];
      infraAttrs = infraWorkloads ++ map (name: "${name}-dev") infraWorkloads;
      tfWorkloads = workloads ++ infraWorkloads;
      checkAttrs = allAttrs ++ infraAttrs;

      # Environments for the `tf` wrapper / Taskfile: each maps to the guest
      # system's attr suffix, its terranix state dir, and its incus remote.
      # Rendered into the `tf` shell app so it needs no runtime Nix eval.
      inv = import ./inventory.nix;
      defaultEnv = "homelab";
      envCases = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          envName: cfg:
          let
            host = cfg.hosts.${cfg.defaultHost};
            suffix = if envName == defaultEnv then "" else "-${envName}";
            dir = if envName == defaultEnv then "terraform" else "terraform/${envName}";
            serviceRemotes = lib.concatStringsSep "\n              " (
              lib.mapAttrsToList (
                svc: _:
                let
                  remote = cfg.hosts.${inv.hostFor envName svc}.remote;
                in
                ''${svc}) remote="${remote}" ;;''
              ) inv.services
            );
          in
          ''
            ${envName})
              attr="$name${suffix}"; workdir="${dir}/$name"
              case "$name" in
                ${serviceRemotes}
                *) remote="${host.remote}" ;;
              esac
              ;;
          ''
        ) inv.envs
      );

      # One workload's system for a env.
      mkSystem =
        env: name:
        let
          meta = metaFor name;
        in
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = (meta.specialArgs or { }) // {
            inherit env name;
          };
          modules =
            lib.optionals (meta.sops or true) [
              sops-nix.nixosModules.sops
              # Restic client (shared); only acts on guests that set
              # `local.backup.paths`, and needs sops for the repo credentials.
              ./modules/backup.nix
              # `dev` guests decrypt with the Mac's age key (pushed at deploy),
              # so no secret re-keying/overlay is needed.
              ./modules/sops-env.nix
            ]
            ++ meta.extraModules or [ ]
            ++ [
              ./modules/local.nix
              ./modules/lxc-credentials.nix
              # Container-specific size cuts (no self-build/install tooling,
              # docs, or nixpkgs-source flake pin); see modules/minimal.nix.
              ./modules/minimal.nix
              ./modules/monitoring-agent.nix
              ./modules/nix-cache.nix
              # Reload nginx when an ACME cert lands after nginx started.
              ./modules/nginx-acme-reload.nix
              ./guests/${name}
            ];
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ terranix.flakeModule ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
      ];

      # Homelab systems keep their bare names; the local testbed variants are
      # suffixed `-dev`.
      flake.nixosConfigurations =
        lib.genAttrs workloads (mkSystem "homelab")
        // lib.listToAttrs (map (name: lib.nameValuePair "${name}-dev" (mkSystem "dev" name)) workloads);

      perSystem =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          tf = pkgs.writeShellApplication {
            name = "tf";
            runtimeInputs = [
              pkgs.terranix
              pkgs.opentofu
              # Used by the instance `local-exec` provisioner to seed the
              # guest's root SSH key on create.
              pkgs.incus-lts.client
              # `tf` evaluates the flake to build the terranix JSON.
              pkgs.nix
            ];
            text = ''
              if [ $# -lt 2 ]; then
                echo "Usage: [ENV=<env>] tf <name> <init|plan|apply|destroy> [tofu args...]"
                echo "Workloads: ${lib.concatStringsSep " " tfWorkloads}"
                echo "Envs: ${lib.concatStringsSep " " (lib.attrNames inv.envs)}"
                exit 1
              fi
              name="$1"
              action="$2"
              shift 2

              case "$action" in
                init|plan|apply|destroy) ;;
                *) echo "Unknown action: $action (init|plan|apply|destroy)"; exit 1 ;;
              esac

              # Which environment to target. `dev` suffixes the guest attr and
              # keeps its terranix state under terraform/<env>/.
              env="''${ENV:-${defaultEnv}}"
              attr=""
              workdir=""
              remote=""
              case "$env" in
              ${envCases}
                *) echo "Unknown ENV: $env" >&2; exit 1 ;;
              esac

              # The terranix `local-exec` provisioner calls the bare `incus`
              # CLI; pin it (and any manual debugging) to the env's server.
              export INCUS_REMOTE="$remote"

              json="$(nix build ".#$attr.config" --no-link --print-out-paths)"
              mkdir -p "$workdir"
              ln -sf "$json" "$workdir/config.tf.json"
              cd "$workdir"
              case "$action" in
                init) tofu init "$@" ;;
                *) tofu init && tofu "$action" "$@" ;;
              esac
            '';
          };

          # One check per workload, so the inner loop can evaluate a single
          # workload (`task check -- <name>`) instead of every workload. Each
          # forces the workload's toplevel (guests only) and its terranix config
          # (eval, not build): it fails if either stops evaluating. DNS is
          # terranix-only, so it has no toplevel to force.
          evalChecks = lib.genAttrs checkAttrs (
            name:
            let
              guest = builtins.elem name allAttrs;
            in
            builtins.deepSeq
              (
                lib.optionals guest [
                  self.nixosConfigurations.${name}.config.system.build.toplevel.drvPath
                ]
                ++ [
                  config.terranix.terranixConfigurations.${name}.result.terraformConfiguration.drvPath
                ]
              )
              (
                pkgs.runCommand "eval-${name}" { } ''
                  touch $out
                ''
              )
          );
        in
        {
          terranix.terranixConfigurations =
            lib.genAttrs workloads (name: {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/envs/homelab.nix
                {
                  local.incus.defaultRemote = (inv.envs.homelab.hosts.${inv.hostFor "homelab" name}).remote;
                }
                ./terraform/${name}
              ];
            })
            // lib.listToAttrs (
              map (
                name:
                lib.nameValuePair "${name}-dev" {
                  terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
                  modules = [
                    ./terraform/common.nix
                    ./terraform/envs/dev.nix
                    {
                      local.incus.defaultRemote = (inv.envs.dev.hosts.${inv.hostFor "dev" name}).remote;
                    }
                    ./terraform/${name}
                  ];
                }
              ) workloads
            )
            // {
              dns = {
                terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
                modules = [
                  ./terraform/common.nix
                  ./terraform/envs/homelab.nix
                  {
                    local.incus.defaultRemote = (inv.envs.homelab.hosts.${inv.hostFor "homelab" "dns"}).remote;
                  }
                  ./terraform/dns
                ];
              };
              dns-dev = {
                terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
                modules = [
                  ./terraform/common.nix
                  ./terraform/envs/dev.nix
                  {
                    local.incus.defaultRemote = (inv.envs.dev.hosts.${inv.hostFor "dev" "dns"}).remote;
                  }
                  ./terraform/dns
                ];
              };
            };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.opentofu
              pkgs.terranix
              # Drive the incus remotes from the Mac for bootstrap/debugging.
              pkgs.incus-lts.client
              # `task dev-access-*`: parse `colima status --json` and verify
              # dev name resolution.
              pkgs.jq
              pkgs.bind
              pkgs.nixfmt
              # Edit secrets and derive age recipients from SSH keys.
              pkgs.sops
              pkgs.age
              pkgs.ssh-to-age
              # `task dr-restore`: restic copy a homelab repo into the dev env.
              pkgs.restic
              # Administer the kanidm (idm) workload; Kanidm is CLI-first.
              pkgs.kanidm_1_11
              # Push closures to the Attic cache workload and the external
              # Cachix fallback (`task cache-push`).
              pkgs.attic-client
              pkgs.cachix
              tf
            ];
            # sops does not read ~/.ssh/id_ed25519 directly; derive a native age
            # identity from it on the fly (matches nix-homelab-hosts).
            shellHook = ''
              export SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i $HOME/.ssh/id_ed25519"
            '';
          };

          formatter = pkgs.writeShellApplication {
            name = "fmt-nix-workloads";
            runtimeInputs = [
              pkgs.fd
              pkgs.nixfmt
            ];
            text = ''
              if [ "$#" -eq 0 ]; then
                fd --extension nix --exec nixfmt {}
              elif [ "$1" = "--check" ]; then
                fd --extension nix --exec nixfmt --check {}
              else
                nixfmt "$@"
              fi
            '';
          };

          packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # Smallest end-to-end guest test: the skeleton has no secrets or
            # external services, so it proves the shared guest shape still
            # boots and runs sshd. Needs a KVM-capable aarch64-linux builder
            # (the Mac linux-builder only has nixos-test, not kvm), so it is a
            # package rather than part of `nix flake check`.
            example-vm = pkgs.testers.nixosTest {
              name = "example-guest";
              nodes.machine =
                { modulesPath, ... }:
                {
                  disabledModules = [ "${modulesPath}/virtualisation/lxc-container.nix" ];
                  imports = [ ./guests/example ];
                  boot.isContainer = false;
                };
              testScript = ''
                machine.wait_for_unit("multi-user.target")
                machine.succeed("systemctl is-system-running")
                machine.succeed("systemctl is-active sshd.service")
              '';
            };
          };

          checks = evalChecks // {
            # Inventory-level DNS invariant: the terraform/dns config writes one
            # A record per service and one CNAME per alias, keyed by name. Two
            # services claiming the same name (or a canonical name colliding
            # with an alias) would silently overwrite the other record, so fail
            # the eval instead.
            dns-zone =
              let
                names = lib.concatMap (
                  name:
                  let
                    svc = inv.services.${name};
                  in
                  lib.optionals (svc.dns != [ ]) (
                    [ name ] ++ lib.filter (alias: alias != name && alias != "ns1") svc.dns
                  )
                ) (builtins.attrNames inv.services);
                duplicate = lib.filter (name: builtins.length (lib.filter (x: x == name) names) > 1) (
                  lib.unique names
                );
              in
              if duplicate != [ ] then
                throw "duplicate DNS names in inventory: ${lib.concatStringsSep ", " duplicate}"
              else
                pkgs.runCommand "dns-zone" { } "touch $out";

            # Aggregate, so `nix flake check` / `task check` still covers every
            # workload. It just builds the per-workload checks.
            eval-all = pkgs.linkFarm "eval-all" (
              map (name: {
                name = name;
                path = evalChecks.${name};
              }) checkAttrs
            );

            # The orchestration shell lives outside `nix fmt`; lint it.
            shellcheck =
              pkgs.runCommand "shellcheck"
                {
                  nativeBuildInputs = [ pkgs.shellcheck ];
                  src = self;
                }
                ''
                  cd "$src"
                  shellcheck scripts/*.sh
                  touch $out
                '';

            # systemd-journal-remote rejects SplitMode=none unless --output is
            # a file (not a directory). Keep that semantic check close to the
            # service definition so a typo cannot repeat the failed deploy.
            journal-remote-args =
              let
                exec =
                  self.nixosConfigurations.monitoring.config.systemd.services.journal-remote.serviceConfig.ExecStart;
              in
              if
                lib.hasInfix "--split-mode=none" exec && lib.match ".*--output=[^ ]*\\.journal( |$).*" exec == null
              then
                throw "journal-remote: --split-mode=none requires --output=FILE"
              else
                pkgs.runCommand "journal-remote-args" { } "touch $out";

            # Formatting gate, matching `nix fmt`.
            fmt =
              pkgs.runCommand "fmt-check"
                {
                  nativeBuildInputs = [
                    pkgs.fd
                    pkgs.nixfmt
                  ];
                  src = self;
                }
                ''
                  cd "$src"
                  fd --extension nix --exec nixfmt --check {}
                  touch $out
                '';
          };
        };
    };
}
