{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkIf types;
  cfg = config.local.backup;
  hostName = config.networking.hostName;
in
{
  # Shared restic client: every guest with state opts in by listing the paths to
  # protect. It pushes an encrypted snapshot to the `backup` workload's restic
  # REST server as `rest:http://backup.<domain>/<hostname>`. Imported only by
  # guests that also import sops-nix (see flake.nix), since the repo password and
  # the REST credentials come from sops.
  options.local.backup = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run a daily restic backup of `paths` to the backup workload.";
    };
    repository = mkOption {
      type = types.str;
      default = "rest:http://backup.${config.local.domain}:8000";
      description = "Restic REST server base URL; the hostname is appended per guest.";
    };
    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths to back up. Empty (the default) disables backup entirely.";
    };
    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Restic exclude patterns.";
    };
    prepareCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Script run before the backup (e.g. a database dump).";
    };
    cleanupCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Script run after the backup (e.g. remove the dump).";
    };
  };

  config = mkIf (cfg.enable && cfg.paths != [ ]) {
    sops.secrets = {
      restic_password.sopsFile = ../secrets/backup.yaml;
      restic_rest_password.sopsFile = ../secrets/backup.yaml;
    };

    # Rest-server credentials; systemd reads the EnvironmentFile as root, so the
    # copy never lands in the store or the world-readable unit.
    sops.templates."restic-rest.env".content = ''
      RESTIC_REST_USERNAME=restic
      RESTIC_REST_PASSWORD=${config.sops.placeholder.restic_rest_password}
    '';

    services.restic.backups.system = {
      repository = "${cfg.repository}/${hostName}";
      passwordFile = config.sops.secrets.restic_password.path;
      environmentFile = config.sops.templates."restic-rest.env".path;
      initialize = true;
      paths = cfg.paths;
      exclude = cfg.exclude;
      backupPrepareCommand = cfg.prepareCommand;
      backupCleanupCommand = cfg.cleanupCommand;
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 6"
      ];
      timerConfig = {
        OnCalendar = "03:30";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # Backup health for the dashboards/alerts: this guest's repo is inspected
    # (restic snapshots/check/stats) and exposed on loopback, scraped by the
    # same Alloy agent. Hand-rolled rather than services.prometheus.exporters.restic
    # because that module passes the repo password through a systemd credential,
    # which the distrobuilder shim strips without `local.lxc.allowSystemdCredentials`
    # - here the password is just an env var from a sops secret.
    systemd.services.restic-exporter = {
      description = "Prometheus exporter for the guest's restic repository";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.restic ];
      environment = {
        RESTIC_REPOSITORY = "${cfg.repository}/${hostName}";
        RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        RESTIC_CACHE_DIR = "/var/cache/restic-exporter";
        LISTEN_ADDRESS = "127.0.0.1";
        LISTEN_PORT = "9753";
        # Inspecting the repo is not free; 6h is plenty for a daily backup.
        REFRESH_INTERVAL = "21600";
      };
      serviceConfig = {
        ExecStart = "${pkgs.prometheus-restic-exporter}/bin/restic-exporter.py";
        EnvironmentFile = config.sops.templates."restic-rest.env".path;
        CacheDirectory = "restic-exporter";
        Restart = "on-failure";
      };
    };

    environment.etc."alloy/restic-exporter.alloy".text = ''
      prometheus.scrape "restic_exporter" {
        targets    = [{ __address__ = "127.0.0.1:9753" }]
        job_name   = "restic-exporter"
        forward_to = [prometheus.relabel.host.receiver]
      }
    '';
  };
}
