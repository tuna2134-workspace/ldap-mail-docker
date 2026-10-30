SHELL := /bin/bash
COMPOSE ?= docker compose

.DEFAULT_GOAL := help
.PHONY: help env build up down reset restart logs ps config test dkim \
        add-user set-forward ldap-users cert-status cert-renew

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

env: ## Create .env from .env.example if it does not exist
	@test -f .env || { \
		cp .env.example .env; \
		echo "Created .env. Edit the values, then run 'make up' again."; \
		exit 1; \
	}

build: env ## Build all images
	$(COMPOSE) build

up: env ## Build and start the stack
	$(COMPOSE) up -d --build

down: ## Stop the stack (volumes are kept)
	$(COMPOSE) down

reset: ## Stop the stack and DELETE mail, LDAP, certificates and Redis data
	$(COMPOSE) down -v

restart: ## Restart all containers
	$(COMPOSE) restart

logs: ## Follow all logs
	$(COMPOSE) logs -f --tail=100

ps: ## Show container status
	$(COMPOSE) ps

config: ## Validate and print the rendered Compose configuration
	$(COMPOSE) config

test: ## Run the end-to-end smoke test against the running stack
	python3 tests/smoke_test.py

dkim: ## Print the DKIM DNS record
	./scripts/dkim-record.sh

add-user: ## Add a user: make add-user ARGS='-u jdoe -n "John Doe" -m jdoe@example.com'
	./scripts/ldap-add-user.sh $(ARGS)

set-forward: ## Set/clear forwarding: make set-forward ARGS='jdoe target@example.net'
	./scripts/ldap-set-forward.sh $(ARGS)

ldap-users: ## List mail accounts from LDAP
	$(COMPOSE) exec -T ldap sh -c 'ldapsearch -x -H ldap://127.0.0.1:389 \
		-D "$$LDAP_ADMIN_DN" -w "$$LDAP_ADMIN_PASSWORD" -b "$$LDAP_BASE_DN" \
		"(objectClass=mailAccount)" uid cn mail mailForward'

cert-status: ## Show certbot certificate status
	$(COMPOSE) exec -T certbot certbot certificates

cert-renew: ## Run certbot renew now
	$(COMPOSE) exec -T certbot certbot renew
