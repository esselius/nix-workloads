{ ... }: {
  # Local Colima run. Colima's incus client is configured for us, so the
  # provider just uses the "colima" remote from ~/.config/incus (no inline
  # remote, no generated client cert).
  local.incus = {
    defaultRemote = "colima";
    remote = [ ];
    generateClientCertificates = false;
    acceptRemoteCertificate = true;
  };

  # No physical LAN uplink inside the VM.
  local.lan.enable = false;
}
