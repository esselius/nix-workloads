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
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      terranix,
      sops-nix,
      ...
    }:
    let
      lib = nixpkgs.lib;

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
        coredns = {
          sops = false;
        };
        home-assistant = {
          sops = false;
          specialArgs = {
            pyproject-nix-lib = inputs.pyproject-nix.lib;
          };
        };
      };
      metaFor = name: guestMeta.${name} or { sops = true; };

      # One workload's system for a given profile ("homelab" | "local").
      mkSystem =
        profile: name:
        let
          meta = metaFor name;
        in
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = (meta.specialArgs or { }) // {
            inherit profile;
          };
          modules = lib.optionals (meta.sops or true) [ sops-nix.nixosModules.sops ] ++ [
            ./modules/local.nix
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./modules/nix-cache.nix
            ./profiles/${profile}.nix
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

      # Homelab systems under the bare name; local Colima variants suffixed
      # `-local` (keeps the `nixosConfigurations` root output key).
      flake.nixosConfigurations =
        lib.genAttrs workloads (mkSystem "homelab")
        // lib.listToAttrs (
          map (name: lib.nameValuePair "${name}-local" (mkSystem "local" name)) workloads
        );

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
            ];
            text = ''
              if [ $# -lt 2 ]; then
                echo "Usage: tf <name> <init|plan|apply|destroy> [tofu args...]"
                echo "Available: ${lib.concatStringsSep " " workloads}"
                exit 1
              fi
              name="$1"
              action="$2"
              shift 2

              case "$action" in
                init|plan|apply|destroy) ;;
                *) echo "Unknown action: $action (init|plan|apply|destroy)"; exit 1 ;;
              esac

              # PROFILE=local targets the Colima variants and a separate state dir.
              # `path:` (not the git flake) so the gitignored secrets overlay is
              # visible to Nix.
              profile="''${PROFILE:-homelab}"
              if [ "$profile" = local ]; then
                attr="$name-local"
                workdir="terraform/local/$name"
                ref="path:."
              else
                attr="$name"
                workdir="terraform/$name"
                ref="."
              fi
              echo "tf: profile=$profile name=$name -> $workdir"

              json="$(nix build "$ref#$attr.config" --no-link --print-out-paths)"
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
          # guest (`task check -- <name>`) instead of every workload. Each
          # forces this guest's toplevel and its terranix config (eval, not
          # build): it fails if either stops evaluating.
          evalChecks = lib.genAttrs workloads (
            name:
            builtins.deepSeq
              [
                self.nixosConfigurations.${name}.config.system.build.toplevel.drvPath
                config.terranix.terranixConfigurations.${name}.result.terraformConfiguration.drvPath
              ]
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
                ./terraform/${name}
              ];
            })
            // lib.listToAttrs (
              map (
                name:
                lib.nameValuePair "${name}-local" {
                  terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
                  # Separate workdir so local state never collides with the homelab.
                  workdir = "local/${name}";
                  modules = [
                    ./terraform/common.nix
                    ./terraform/local.nix
                    ./terraform/${name}
                  ];
                }
              ) workloads
            );

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.opentofu
              pkgs.terranix
              # Drive the incus remotes from the Mac for bootstrap/debugging.
              pkgs.incus-lts.client
              pkgs.nixfmt
              # Edit secrets and derive age recipients from SSH keys.
              pkgs.sops
              pkgs.age
              pkgs.ssh-to-age
              # Administer the kanidm (idm) workload; Kanidm is CLI-first.
              pkgs.kanidm_1_11
              # Push closures to the Attic cache workload (`task cache-push`).
              pkgs.attic-client
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
              else
                nixfmt "$@"
              fi
            '';
          };

          checks = evalChecks // {
            # Aggregate, so `nix flake check` / `task check` still covers every
            # workload. It just builds the per-workload checks.
            eval-all = pkgs.linkFarm "eval-all" (
              map (name: {
                name = name;
                path = evalChecks.${name};
              }) workloads
            );

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
