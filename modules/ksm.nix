{ config, lib, ... }:
{
  options.local.ksm.services = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Services to mark with MemoryKSM=yes for KSM page merging.";
  };

  config.systemd.services = lib.genAttrs config.local.ksm.services (name: {
    serviceConfig.MemoryKSM = "yes";
  });
}
