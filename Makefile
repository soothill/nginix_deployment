SHELL := /bin/bash

WORKDIR ?= /opt/nginix_deployment
SYSTEMD_DIR ?= /etc/systemd/system
COMPOSE ?= podman compose
ENV_FILE ?= .env
RSYNC ?= rsync
INSTALL ?= install
DATA_DIRS := data/certbot/conf data/certbot/www logs/nginx

.PHONY: help init env up down test certonly renew reload deploy install-systemd enable-timer

help:
	@printf "Available targets:\n"
	@printf "  %-25s %s\n" \
	  help "Show this help message" \
	  init "Create runtime data/log directories" \
	  env "Ensure $(ENV_FILE) exists (copy from .env.example)" \
	  up "Start nginx + dependencies via podman compose" \
	  down "Stop the compose stack" \
	  test "Run nginx config test inside a throwaway container" \
	  certonly "Issue initial Let's Encrypt cert(s) using .env values" \
	  renew "Renew certificates and reload nginx" \
	  reload "Reload nginx configuration" \
	  deploy "Rsync repo (excluding data/logs) to $(WORKDIR)" \
	  install-systemd "Install certbot systemd units to $(SYSTEMD_DIR)" \
	  enable-timer "Enable + start certbot-renew.timer";

init:
	@mkdir -p $(DATA_DIRS)

env:
	@if [ ! -f $(ENV_FILE) ]; then \
		cp .env.example $(ENV_FILE); \
		echo "Created $(ENV_FILE) from .env.example"; \
	else \
		echo "$(ENV_FILE) already exists"; \
	fi

up: init
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

test: init
	$(COMPOSE) run --rm nginx nginx -t

certonly: init
	@bash -c 'set -euo pipefail; set -a; . $(ENV_FILE); set +a; \
		$(COMPOSE) run --rm certbot certonly \
		  --webroot -w /var/www/certbot \
		  --email "$$LETSENCRYPT_EMAIL" --agree-tos --no-eff-email \
		  -d "$$LETSENCRYPT_DOMAIN" $${LETSENCRYPT_EXTRA_DOMAINS:+ -d $${LETSENCRYPT_EXTRA_DOMAINS//,/ -d }}'

renew: init
	@$(COMPOSE) run --rm certbot renew --webroot -w /var/www/certbot --quiet
	@$(COMPOSE) exec nginx nginx -s reload

reload:
	$(COMPOSE) exec nginx nginx -s reload

deploy: init
	@$(RSYNC) -a --delete --exclude '.git' --exclude 'data' --exclude 'logs' --exclude '.env' ./ $(WORKDIR)/
	@echo "Deployment files synced to $(WORKDIR)"

install-systemd:
	@bash -c 'set -euo pipefail; tmp=$$(mktemp); \
		sed "s|/opt/nginix_deployment|$(WORKDIR)|g" systemd/certbot-renew.service > $$tmp; \
		$(INSTALL) -Dm644 $$tmp $(SYSTEMD_DIR)/certbot-renew.service; \
		rm $$tmp'
	$(INSTALL) -Dm644 systemd/certbot-renew.timer $(SYSTEMD_DIR)/certbot-renew.timer

enable-timer: install-systemd
	systemctl daemon-reload
	systemctl enable --now certbot-renew.timer
