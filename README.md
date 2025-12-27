# Nginx reverse proxy on openSUSE MicroOS with Podman and Let's Encrypt

This repository provides a minimal-but-complete deployment for an nginx reverse proxy that terminates TLS with Let's Encrypt certificates while forwarding traffic to internal services. It is intended for openSUSE MicroOS using `podman` (rootless or rootful) and `podman compose`.

## Layout

- `compose.yml` – Podman Compose definition for nginx and certbot.
- `nginx/` – Base nginx configuration and a sample reverse proxy server block.
- `systemd/` – Sample systemd service + timer to automate certbot renewal and reload nginx.
- `.env.example` – Template for environment variables consumed by the Compose stack.

## Prerequisites on MicroOS

1. Install Podman and podman-compose (via `transactional-update pkg install podman podman-compose` then reboot).
2. Create a working directory, e.g. `/opt/nginix_deployment`, and copy this repository there.
3. Copy `.env.example` to `.env` and verify the domain/email settings for your deployment:

   ```bash
   cp .env.example .env
   # Defaults here are tailored for soothill.com
   # Update only if you want different domains or a different cert email contact
   sed -n '1,10p' .env
   ```

4. Adjust `nginx/conf.d/reverse-proxy.conf` to point `backend_service` at your internal endpoint(s). The `server_name` and certificate paths are pre-set for `www.soothill.com` + `pages.soothill.com`; tweak only if you are using different hostnames.

## Makefile shortcuts

A Makefile is included to streamline common tasks. Run `make help` to see all targets.

- `make env` – copy `.env.example` to `.env` if it does not exist.
- `make init` – create runtime directories (`data/certbot/*` and `logs/nginx`).
- `make up` / `make down` – start or stop the Podman Compose stack.
- `make test` – run `nginx -t` in a throwaway container to validate configuration.
- `make certonly` – issue initial certificates using values from `.env`.
- `make renew` – renew certificates and reload nginx immediately.
- `make deploy WORKDIR=/opt/nginix_deployment` – rsync the repo (excluding data/logs/.env) to the target path.
- `make install-systemd WORKDIR=/opt/nginix_deployment SYSTEMD_DIR=/etc/systemd/system` – install the systemd service/timer with the chosen working directory baked in.
- `make enable-timer` – reload systemd and start the renewal timer (depends on `install-systemd`).

## Initial certificate issuance

1. Create runtime directories (certbot expects them to exist):

   ```bash
   mkdir -p data/certbot/conf data/certbot/www logs/nginx
   ```

2. Start nginx so the ACME HTTP-01 challenge can succeed:

   ```bash
   podman compose up -d nginx
   ```

3. Load your `.env` so the shell command can use the variables (or substitute values manually):

   ```bash
   set -a
   source .env
   set +a
   ```

4. Request the certificate (defaults issue `www.soothill.com` with an SAN for `pages.soothill.com`; edit `.env` first if you need different names):

   ```bash
   podman compose run --rm certbot certonly \
     --webroot -w /var/www/certbot \
     --email "$LETSENCRYPT_EMAIL" --agree-tos --no-eff-email \
     -d "$LETSENCRYPT_DOMAIN"${LETSENCRYPT_EXTRA_DOMAINS:+ -d ${LETSENCRYPT_EXTRA_DOMAINS//,/ -d }}
   ```

5. Reload nginx to serve the new certificate:

   ```bash
   podman compose exec nginx nginx -s reload
   ```

6. Bring up the full stack (nginx stays running; certbot is only run when needed):

   ```bash
   podman compose up -d
   ```

## Automated renewals via systemd

1. Copy the systemd units into place (rootful example shown; for rootless use `~/.config/systemd/user` and `systemctl --user`):

   ```bash
   install -m 644 systemd/certbot-renew.service /etc/systemd/system/
   install -m 644 systemd/certbot-renew.timer /etc/systemd/system/
   ```

   Update the `WorkingDirectory` and `EnvironmentFile` paths inside `certbot-renew.service` if you placed the repo elsewhere.

2. Enable and start the timer (by default it runs at 00:00 and 12:00 daily):

   ```bash
   systemctl daemon-reload
   systemctl enable --now certbot-renew.timer
   ```

The timer runs twice daily. When renewal succeeds, it reloads nginx to pick up the new certificates.

## Customizing the reverse proxy

- Update `upstream backend_service` in `nginx/conf.d/reverse-proxy.conf` with the internal targets you want to expose.
- Add additional `location` blocks for multiple services or paths.
- When adding new domains, include them in `.env` via `LETSENCRYPT_EXTRA_DOMAINS` and rerun the `certbot certonly` command.

## Additional configuration options to consider

- **TLS hardening:** OCSP stapling (`ssl_stapling on`), session cache/timeouts, and a trusted DNS `resolver` are pre-wired in `nginx/conf.d/reverse-proxy.conf`. Adjust the resolver IPs if you prefer different DNS providers.
- **Request sizing/timeouts:** Tune `client_max_body_size`, `proxy_connect_timeout`, and `proxy_read_timeout` to match your applications' upload or latency profiles.
- **Rate limiting:** A commented `limit_req` example in `nginx/conf.d/reverse-proxy.conf` can be enabled to throttle abusive clients before traffic reaches your backends.
- **Firewall/ports:** For rootless Podman, map nginx to high ports and use `firewalld`/`nftables` DNAT rules to forward 80/443 from the host.
- **Observability:** Tail logs from `logs/nginx` or add JSON log_format to feed a collector. Consider enabling `stub_status` in a separate location block for simple health metrics.

## Notes

- The Compose file uses port mappings `80:80` and `443:443`. If you prefer a rootless deployment, map to high ports and use a firewall/NAT rule to forward 80/443.
- Certificate and log data are intentionally excluded from version control via `.gitignore`.
- The `certbot` container stays idle by default; `podman compose run --rm certbot ...` spins up a short-lived container for issuance or renewal.
