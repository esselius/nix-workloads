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
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ terranix.flakeModule ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
      ];

      flake.nixosConfigurations = {
        example = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./guests/example
          ];
        };
        mosquitto = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./guests/mosquitto
          ];
        };
        coredns = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./guests/coredns
          ];
        };
        step-ca = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./guests/step-ca
          ];
        };
        monitoring = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/lxc-credentials.nix
            ./modules/monitoring-agent.nix
            ./guests/monitoring
          ];
        };
      };

      perSystem =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          # Workloads are sibling directories under terraform/; each becomes a
          # terranix configuration named after the directory.
          workloads = [
            "example"
            "mosquitto"
            "coredns"
            "step-ca"
            "monitoring"
          ];

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

              json="$(nix build ".#$name.config" --no-link --print-out-paths)"
              workdir="terraform/$name"
              mkdir -p "$workdir"
              ln -sf "$json" "$workdir/config.tf.json"
              cd "$workdir"
              case "$action" in
                init) tofu init "$@" ;;
                *) tofu init && tofu "$action" "$@" ;;
              esac
            '';
          };
        in
        {
          terranix.terranixConfigurations = {
            example = {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/example
              ];
            };
            mosquitto = {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/mosquitto
              ];
            };
            coredns = {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/coredns
              ];
            };
            step-ca = {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/step-ca
              ];
            };
            monitoring = {
              terraformWrapper.package = pkgs.opentofu.withPlugins (_: [ ]);
              modules = [
                ./terraform/common.nix
                ./terraform/monitoring
              ];
            };
          };

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

          checks =
            let
              # Eval does not require the target platform, so a Darwin
              # `nix flake check` can still prove the aarch64-linux guest
              # systems evaluate.
              guestDrvs = [
                self.nixosConfigurations.example.config.system.build.toplevel
                self.nixosConfigurations.mosquitto.config.system.build.toplevel
                self.nixosConfigurations.coredns.config.system.build.toplevel
                self.nixosConfigurations.step-ca.config.system.build.toplevel
                self.nixosConfigurations.monitoring.config.system.build.toplevel
              ];
              terraformConfigs = builtins.attrValues (
                lib.mapAttrs (_: cfg: cfg.result.terraformConfiguration) config.terranix.terranixConfigurations
              );
            in
            {
              # Force evaluation of every guest toplevel and terranix config
              # (eval, not build): fails here if anything stops evaluating.
              eval-all = builtins.deepSeq (map (d: d.drvPath) (guestDrvs ++ terraformConfigs)) (
                pkgs.runCommand "eval-all" { } ''
                  touch $out
                ''
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
