{ pkgs, ... }:

{
  imports = [
    ./apps/monobara-codex.nix
    ./services/deploy-webhook.nix
    ./services/postgres-admin.nix
  ];

  networking = {
    hostName = "ovh-vps";
    useDHCP = true;
    firewall.allowedTCPPorts = [ 80 443 ];
    firewall.allowedUDPPorts = [ 41641 ];
    firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 53 ];
    firewall.interfaces."tailscale0".allowedUDPPorts = [ 53 ];
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
      Environment = [
        "GIT=${pkgs.git}/bin/git"
        "SSH=${pkgs.openssh}/bin/ssh"
      ];
      ExecStart = "${pkgs.python3}/bin/python ${./scripts/pull-nixos-config.py}";
    };
    unitConfig.ConditionPathExists = "/root/.ssh/nixos-vps_deploy";
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

  services.dnsmasq = {
    enable = true;
    settings = {
      bind-interfaces = true;
      interface = "tailscale0";
      no-resolv = true;
      address = "/admin.typestrict.dev/100.74.236.19";
    };
  };

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
