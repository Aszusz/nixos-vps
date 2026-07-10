{ pkgs, ... }:

{
  networking = {
    hostName = "ovh-vps";
    useDHCP = true;
    firewall.allowedTCPPorts = [ 80 443 ];
    firewall.allowedUDPPorts = [ 41641 ];
    firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 ];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "adrianszuszkiewicz@gmail.com";
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    virtualHosts."typestrict.dev" = {
      enableACME = true;
      forceSSL = true;

      locations."/".extraConfig = ''
        default_type text/plain;
        return 200 "Hello, World!\n";
      '';
    };
  };

  boot.loader.grub.enable = true;

  environment.systemPackages = [ pkgs.git ];

  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  systemd.services.pull-nixos-config = {
    description = "Pull NixOS config from GitHub";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "pull-nixos-config" ''
        set -eu
        repo=git@github.com:Aszusz/nixos-vps.git
        ssh_command="${pkgs.openssh}/bin/ssh -i /root/.ssh/nixos-vps_deploy -o IdentitiesOnly=yes"
        if [ -d /etc/nixos/.git ]; then
          ${pkgs.git}/bin/git -c core.sshCommand="$ssh_command" -C /etc/nixos fetch origin main
          ${pkgs.git}/bin/git -C /etc/nixos reset --hard origin/main
        else
          rm -rf /etc/nixos
          ${pkgs.git}/bin/git -c core.sshCommand="$ssh_command" clone --branch main "$repo" /etc/nixos
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
    openFirewall = false;
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      AllowUsers = [ "adrian" ];
      AuthenticationMethods = "publickey";
      KbdInteractiveAuthentication = false;
      LoginGraceTime = "20s";
      MaxAuthTries = 2;
      PasswordAuthentication = false;
      PermitEmptyPasswords = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
    };
  };

  services.tailscale.enable = true;

  security.sudo.wheelNeedsPassword = false;

  users.users.adrian = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECEQ/z3bwstFumB2JDdTZ8V97ttrAXNC3zgTePbXJK3 ovh-vps"
    ];
  };

  time.timeZone = "Europe/Warsaw";

  system.stateVersion = "25.11";
}
