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

Apps are deployed by GitHub Actions publishing GHCR images and POSTing signed release metadata to the VPS webhook:

```text
https://fullstack.typestrict.dev/deploy/<app>
```

The webhook runs locally as `deploy-webhook.service` and starts an app-specific deploy unit, for example `monobara-codex-deploy@<tag>.service`.

This branch keeps the VPS as the app runtime source of truth: NixOS owns the host PostgreSQL service, Podman containers, systemd units, nginx routes, ACME, env-file locations, and deploy wiring. App repos publish images; they do not supply the runtime Compose definition.

Deploy requests are authenticated with an HMAC signature over the exact JSON body. The VPS rejects stale timestamps and replays.

Required secret files for `monobara-codex`:

```sh
sudo install -d -m 0700 -o root -g root /var/lib/deploy-webhook /var/lib/monobara-codex
```

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/deploy-webhook/env <<'EOF'
DEPLOY_WEBHOOK_SECRET=change-me
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
POSTGRES_USER=monobara
POSTGRES_PASSWORD=change-me
POSTGRES_DB=monobara
POSTGRES_PORT=5432
DATABASE_URL=postgres://monobara:change-me@127.0.0.1:5432/monobara
EOF
```

After creating the files, apply the NixOS config and deploy a known tag:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#ovh-vps
sudo systemctl start monobara-codex-deploy@v0.2.10.service
curl -fsS https://fullstack.typestrict.dev/api/health
```

To send the same metadata CI sends:

```sh
tag=v0.2.10
body=$(printf '{"repo":"Aszusz/monobara-codex","tag":"%s"}' "$tag")
timestamp=$(date +%s)
signature=$(printf '%s.%s' "$timestamp" "$body" | openssl dgst -sha256 -hmac "$DEPLOY_WEBHOOK_SECRET" -binary | xxd -p -c 256)
curl -fsS \
  -X POST \
  -H "X-Deploy-Timestamp: $timestamp" \
  -H "X-Deploy-Signature: sha256=$signature" \
  -H "Content-Type: application/json" \
  --data "$body" \
  https://fullstack.typestrict.dev/deploy/monobara-codex
```

To add another app, add a new app module under `apps/`, register it in `services.deployWebhook.apps`, create app-specific env files under `/var/lib/<app>/`, and have that repo's CD workflow POST signed release metadata with the shared deploy secret.

## Postgres admin UI

Per-app Postgres inspection is provided by pgweb. Each app gets a separate read-only pgweb instance, separate connection string, and separate Tailscale-only virtual host.

The `monobara-codex` admin UI is configured at:

```text
https://monobara-db.admin.typestrict.dev
```

Nginx proxies this host to pgweb on `127.0.0.1:18081` and denies non-Tailscale source addresses. Public DNS should point `*.admin.typestrict.dev` at the VPS public IP for ACME, while Tailscale split DNS should send `admin.typestrict.dev` to the VPS Tailscale IP `100.74.236.19`. The VPS runs dnsmasq on `tailscale0`, answers `*.admin.typestrict.dev` as `100.74.236.19`, and forwards other DNS queries to public resolvers. Public clients should receive `403 Forbidden`.

The NixOS config creates or updates the read-only Postgres role and grants access to the app-owned schemas declared in `services.postgresAdmin.apps.<name>.schemas`.

Create the pgweb environment file on the VPS:

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/monobara-codex/pgweb.env <<'EOF'
PGWEB_DATABASE_URL=postgres://monobara_readonly:change-me@127.0.0.1:5432/monobara?sslmode=disable
EOF
```

After deploy, verify from the VPS:

```sh
systemctl is-active pgweb-monobara-codex nginx tailscaled
curl -fsS -o /dev/null http://127.0.0.1:18081
```

Verify from outside Tailscale that `https://monobara-db.admin.typestrict.dev` is denied, then verify from a Tailscale client that it loads.
