{
  # Homelab env: everything comes from the defaults derived from inventory.nix
  # (hosts.rpi5-8gb, zone int.esselius.dev). Listed explicitly so the flake's
  # env wiring is symmetric with `dev.nix`.
  local.env = "homelab";
}
