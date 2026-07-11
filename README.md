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

App stacks are run with Docker Compose. Each app repo owns its `docker-compose.yml`; this repo owns the host wiring around it: Docker, nginx, ACME, systemd, env-file locations, webhook validation, Compose policy checks, and the deploy unit. During deploy the VPS fetches the Compose file from the exact app commit supplied by CI and verifies its SHA256 before running it.

App repositories are trusted deployment code, similar to a full-stack app deployed to Vercel. The platform still rejects dangerous Compose capabilities before deploy: privileged containers, host namespaces, Docker socket mounts, devices, extra capabilities, unsafe security options, non-loopback port publishing, and host bind mounts outside the app directory.

Deploy requests are authenticated with an HMAC signature over the exact JSON body. The VPS rejects stale timestamps and replays. Image refs may use either the pushed tag or an immutable digest; digests are preferred.

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
body=$(printf '{"repo":"Aszusz/monobara-codex","tag":"%s","commit":"%s","composeSha256":"%s","images":{"WEB_IMAGE":"ghcr.io/aszusz/monobara-codex-web:%s","API_IMAGE":"ghcr.io/aszusz/monobara-codex-api:%s"}}' "$tag" "$commit" "$compose_sha256" "$tag" "$tag")
timestamp=$(date +%s)
signature=$(printf '%s.%s' "$timestamp" "$body" | openssl dgst -sha256 -hmac "$DEPLOY_WEBHOOK_SECRET" -binary | xxd -p -c 256)
curl -fsS \
  -X POST \
  -H "X-Deploy-Timestamp: $timestamp" \
  -H "X-Deploy-Signature: sha256=$signature" \
  -H "Content-Type: application/json" \
  --data "$body" \
  https://fullstack.typestrict.dev/deploy/monobara-codex
curl -fsS https://fullstack.typestrict.dev/health
```

To deploy immutable image digests instead of tags, send refs like `ghcr.io/aszusz/monobara-codex-web@sha256:<digest>` in `images`. The digest must still use the configured image repository prefix.

To add another app, add a small app declaration under `apps/` using `modules/compose-app.nix`, create app-specific env files under `/var/lib/<app>/`, and have that repo's CD workflow POST signed release metadata with the shared deploy secret.

## Postgres admin UI

Per-app Postgres inspection is provided by pgweb. Each app gets a separate read-only pgweb instance, separate connection string, and separate Tailscale-only virtual host.

The `monobara-codex` admin UI is configured at:

```text
https://monobara-db.admin.typestrict.dev
```

Nginx proxies this host to pgweb on `127.0.0.1:18081` and denies non-Tailscale source addresses. Public DNS should point `*.admin.typestrict.dev` at the VPS public IP for ACME, while Tailscale split DNS should send `admin.typestrict.dev` to the VPS Tailscale IP `100.74.236.19`. The VPS runs dnsmasq on `tailscale0`, answers `*.admin.typestrict.dev` as `100.74.236.19`, and forwards other DNS queries to public resolvers. Public clients should receive `403 Forbidden`.

Create a read-only database user before enabling access. Example SQL for the `monobara` database:

```sql
CREATE USER monobara_readonly WITH PASSWORD 'change-me';
GRANT CONNECT ON DATABASE monobara TO monobara_readonly;
GRANT USAGE ON SCHEMA public TO monobara_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO monobara_readonly;
GRANT USAGE ON SCHEMA drizzle TO monobara_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA drizzle TO monobara_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO monobara_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA drizzle GRANT SELECT ON TABLES TO monobara_readonly;
```

Repeat the schema grants for any additional app-owned schemas that pgweb should inspect.

Create the pgweb environment file on the VPS:

```sh
sudo install -m 0600 -o root -g root /dev/stdin /var/lib/monobara-codex/pgweb.env <<'EOF'
PGWEB_DATABASE_URL=postgres://monobara_readonly:change-me@127.0.0.1:15432/monobara?sslmode=disable
EOF
```

After deploy, verify from the VPS:

```sh
systemctl is-active pgweb-monobara-codex nginx tailscaled
curl -fsS -o /dev/null http://127.0.0.1:18081
```

Verify from outside Tailscale that `https://monobara-db.admin.typestrict.dev` is denied, then verify from a Tailscale client that it loads.
