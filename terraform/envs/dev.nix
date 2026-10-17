{
  # Local development/testbed env: an incus VM on the Mac. Same service names,
  # different zone (`dev.int.esselius.dev`) and address space; no LAN NIC and no
  # Attic cache (see modules/local.nix and terraform/common.nix, which derive
  # everything else from the inventory's `dev` env).
  local.env = "dev";
}
