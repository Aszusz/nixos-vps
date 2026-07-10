# AGENTS.md

Guidance for agents working on this VPS configuration.

- This repo manages the NixOS VPS `ovh-vps` via `flake.nix` and `configuration.nix`.
- Use `ssh ovh-vps` for administration. This should connect over Tailscale as user `adrian`.
- Do not reopen public SSH. Port `22` must remain available only on `tailscale0`.
- Public ports should stay limited to web traffic: `80` and `443`, plus Tailscale UDP `41641`.
- Deploy by pushing to `main`, then running on the VPS: `sudo systemctl start pull-nixos-config.service && sudo nixos-rebuild switch --flake /etc/nixos#ovh-vps`.
- Validate local changes before deploy with `nix flake check`.
- After deploy, verify `ssh ovh-vps`, `systemctl is-active sshd tailscaled nginx`, and `curl https://typestrict.dev/`.
- Root SSH login is intentionally disabled. Use `adrian` with passwordless sudo.
- Do not edit `hardware-configuration.nix` unless hardware/platform details change.
