{ ... }: {
  # Local Colima run: `*.localho.st` names (public DNS points them at 127.0.0.1)
  # and a static wildcard cert issued from the name-constrained `localho.st`
  # intermediate (see certs/local/, generated from github.com/esselius/pki).
  local = {
    domain = "localho.st";

    # Trust the local root; guests present the static wildcard.
    caFiles = [ ../certs/local/root-ca.crt ];
    tls = {
      cert = ../certs/local/localho.st.crt;
      key = ../certs/local/localho.st.key;
    };

    # A local step-ca on the constrained intermediate would live here; unused
    # until a TLS workload needs ACME.
    acmeServer = "https://localho.st:8400/acme/my-acme-provisioner/directory";
    acmeEmail = "acme@localho.st";

    # No Attic locally; deploys copy.
    cache.url = "https://cache.localho.st/homelab";

    # Local secrets overlay (gitignored): onboard re-encrypts a copy here for
    # the Colima guest instead of touching secrets/<name>.yaml.
    sopsDir = ../secrets/local;

    # No physical LAN uplink inside the VM.
    lan.enable = false;
  };

  local.monitoring.enable = false;
}
