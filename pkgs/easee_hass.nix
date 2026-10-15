{
  fetchFromGitHub,
  buildHomeAssistantComponent,
  home-assistant,
  pyproject-nix-lib,
}:

buildHomeAssistantComponent rec {
  owner = "nordicopen";
  domain = "easee";
  version = "0.9.67";

  src = fetchFromGitHub {
    inherit owner;
    repo = "easee_hass";
    tag = "v${version}";
    hash = "sha256-psRr3cJ/sK/Z0dgB27GbW0qAHH2vJt+TdxqDB+Zhkc0=";
  };

  # Build the deps from HA's own Python set (`home-assistant.python3Packages`,
  # i.e. the Python HA runs on), not a separate `pythonNNPackages`. Mixing sets
  # trips the custom-component check when HA is overlaid from another nixpkgs
  # (see the `nixpkgs-ha` input in flake.nix).
  dependencies = [
    (home-assistant.python3Packages.callPackage ./pyeasee.nix { })
    (home-assistant.python3Packages.callPackage ./pysignalr.nix {
      inherit pyproject-nix-lib;
    })
  ];
  nativeBuildInputs = [
    home-assistant.python3Packages.bump2version
  ];
}
