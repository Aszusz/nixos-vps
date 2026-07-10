{ pkgs, ... }:

{
  networking = {
    hostName = "ovh-vps";
    useDHCP = true;
    firewall.allowedTCPPorts = [ 22 ];
  };

  boot.loader.grub.enable = true;

  environment.systemPackages = [ pkgs.git ];

  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqLZQoIUXnbuodrJVVt2Ah9QHSLSFGPtdkTnzyT2tG";
  };

  systemd.services.pull-nixos-config = {
    description = "Pull NixOS config from GitHub";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      Environment = "GIT_SSH_COMMAND=ssh -i /root/.ssh/nixos-vps_deploy -o IdentitiesOnly=yes";
      ExecStart = pkgs.writeShellScript "pull-nixos-config" ''
        set -eu
        repo=git@github.com:Aszusz/nixos-vps.git
        if [ -d /etc/nixos/.git ]; then
          ${pkgs.git}/bin/git -C /etc/nixos fetch origin main
          ${pkgs.git}/bin/git -C /etc/nixos reset --hard origin/main
        else
          rm -rf /etc/nixos
          ${pkgs.git}/bin/git clone --branch main "$repo" /etc/nixos
        fi
      '';
    };
    unitConfig.ConditionPathExists = "/root/.ssh/nixos-vps_deploy";
  };

  systemd.timers.pull-nixos-config = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECEQ/z3bwstFumB2JDdTZ8V97ttrAXNC3zgTePbXJK3 ovh-vps"
  ];

  time.timeZone = "Europe/Warsaw";

  system.stateVersion = "25.11";
}
