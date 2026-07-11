# nixos-vps

NixOS configuration for the OVH VPS.

Apply from the VPS after pulling:

```sh
nixos-rebuild switch --flake /etc/nixos#ovh-vps
```

Pull manually:

```sh
systemctl start pull-nixos-config.service
```

## App deploys

Apps are deployed by GitHub Actions publishing GHCR images and POSTing to the VPS webhook:

```text
https://fullstack.typestrict.dev/deploy/<app>
```

The webhook runs locally as `deploy-webhook.service` and starts an app-specific deploy unit, for example `monobara-deploy@<tag>.service`.

Required secret files for `monobara-codex`:

```sh
sudo install -d -m 0700 -o root -g root /var/lib/deploy-webhook /var/lib/monobara-codex
```

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/deploy-webhook/env <<'EOF'
DEPLOY_WEBHOOK_TOKEN=change-me
DEPLOY_WEBHOOK_PORT=9010
EOF
```

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/monobara-codex/ghcr.env <<'EOF'
GHCR_USERNAME=Aszusz
GHCR_TOKEN_FILE=/var/lib/monobara-codex/ghcr-token
EOF
```

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/monobara-codex/ghcr-token <<'EOF'
<github-token-with-read-packages>
EOF
```

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/monobara-codex/app.env <<'EOF'
BETTER_AUTH_URL=https://fullstack.typestrict.dev
BETTER_AUTH_SECRET=change-me
WEB_URL=https://fullstack.typestrict.dev
PORT=3000
MONOBARA_DB_PASSWORD=change-me
DATABASE_URL=postgres://monobara:change-me@127.0.0.1:5432/monobara
EOF
```

After creating the files, apply the NixOS config and deploy a known tag:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#ovh-vps
sudo systemctl start monobara-deploy@v0.2.10.service
curl -fsS https://fullstack.typestrict.dev/api/health
```

To add another app, add a new app module under `apps/`, add its route to `services/deploy-webhook.nix`, create app-specific env files under `/var/lib/<app>/`, and have that repo's CD workflow POST `{"repo":"owner/repo","tag":"<tag>"}` with the bearer token.
