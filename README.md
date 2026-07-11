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

Apps are deployed by GitHub Actions publishing GHCR images and POSTing immutable release metadata to the VPS webhook:

```text
https://fullstack.typestrict.dev/deploy/<app>
```

The webhook runs locally as `deploy-webhook.service` and starts an app-specific deploy unit with a generated request id, for example `monobara-codex-deploy@<request-id>.service`.

App stacks are run with Docker Compose. Each app repo owns its `docker-compose.yml`; this repo owns the host wiring around it: Docker, nginx, ACME, systemd, env-file locations, webhook validation, and the deploy unit. During deploy the VPS fetches the Compose file from the exact app commit supplied by CI and verifies its SHA256 before running it.

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
WEB_PORT=127.0.0.1:8080
API_PORT=3000
PORT=3000
POSTGRES_USER=monobara
POSTGRES_PASSWORD=change-me
POSTGRES_DB=monobara
POSTGRES_PORT=15432
VITE_API_URL=
EOF
```

After creating the files, apply the NixOS config and deploy a known tag by posting the same metadata CI sends:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#ovh-vps
commit=<full-monobara-codex-commit-sha>
tag=v0.2.10
compose_sha256=$(curl -fsSL "https://raw.githubusercontent.com/Aszusz/monobara-codex/$commit/docker-compose.yml" | sha256sum | cut -d ' ' -f1)
curl -fsS \
  -X POST \
  -H "Authorization: Bearer $DEPLOY_WEBHOOK_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"repo\":\"Aszusz/monobara-codex\",\"tag\":\"$tag\",\"commit\":\"$commit\",\"composeSha256\":\"$compose_sha256\",\"images\":{\"WEB_IMAGE\":\"ghcr.io/aszusz/monobara-codex-web:$tag\",\"API_IMAGE\":\"ghcr.io/aszusz/monobara-codex-api:$tag\"}}" \
  https://fullstack.typestrict.dev/deploy/monobara-codex
curl -fsS https://fullstack.typestrict.dev/health
```

To add another app, add a small app declaration under `apps/` using `modules/compose-app.nix`, register its webhook unit, Compose path, and image allowlist in `services.deployWebhook.apps`, create app-specific env files under `/var/lib/<app>/`, and have that repo's CD workflow POST release metadata with the bearer token.
