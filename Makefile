# homelab — Validation + Deploy.
#
# Quick reference:
#   make validate              — alle Configs prüfen (promtool, yamllint, compose)
#   make deploy-monitoring     — alert-rules.yml + prometheus.yml → cachyos, reload
#   make deploy-cadvisor       — vps-cadvisor → tail, compose up
#   make drift                 — sha256 deploy vs. Repo, Mismatch markieren

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROM_IMG     ?= prom/prometheus:latest
PROM_DIR     := configs/monitoring/prometheus
CACHYOS_HOST ?= cachyos
CACHYOS_DST  ?= /home/alex/monitoring/prometheus
VPS_HOST     ?= tail
VPS_CADV_DST ?= /home/admin/monitoring/cadvisor

.PHONY: help validate validate-prometheus validate-yaml validate-compose \
        deploy-monitoring deploy-cadvisor drift

help:
	@awk '/^[a-zA-Z0-9_-]+:/ {sub(/:.*/,""); print "  " $$0}' Makefile | sort -u

## --- VALIDATE ---------------------------------------------------------------

validate: validate-prometheus validate-yaml validate-compose
	@echo "OK — alle Checks grün."

validate-prometheus:
	@echo "== promtool check rules + config =="
	docker run --rm -v "$$PWD/$(PROM_DIR)":/etc/prometheus:ro \
		--entrypoint promtool $(PROM_IMG) check rules /etc/prometheus/alert-rules.yml
	docker run --rm -v "$$PWD/$(PROM_DIR)":/etc/prometheus:ro \
		--entrypoint promtool $(PROM_IMG) check config /etc/prometheus/prometheus.yml

validate-yaml:
	@echo "== yamllint configs/ =="
	@if command -v yamllint >/dev/null; then \
		yamllint -c .yamllint configs/; \
	else \
		echo "yamllint nicht installiert — überspringe (pip install yamllint)"; \
	fi

validate-compose:
	@echo "== docker compose config (alle Stacks) =="
	@set -e; \
	while IFS= read -r f; do \
		dir=$$(dirname "$$f"); \
		tmpenv=""; \
		if [ -f "$$dir/.env.example" ] && [ ! -f "$$dir/.env" ]; then \
			cp "$$dir/.env.example" "$$dir/.env"; \
			tmpenv="$$dir/.env"; \
			echo "--- $$f (using .env.example as tmp .env)"; \
		else \
			echo "--- $$f"; \
		fi; \
		docker compose -f "$$f" config -q; \
		ret=$$?; \
		[ -n "$$tmpenv" ] && rm -f "$$tmpenv"; \
		if [ "$$ret" != "0" ]; then exit $$ret; fi; \
	done < <(find configs -name 'docker-compose.yml' -o -name 'compose.yaml')

## --- DEPLOY -----------------------------------------------------------------

deploy-monitoring: validate-prometheus
	@echo "== scp prometheus configs → $(CACHYOS_HOST) =="
	ssh $(CACHYOS_HOST) 'cp $(CACHYOS_DST)/alert-rules.yml  $(CACHYOS_DST)/alert-rules.yml.bak-$$(date +%Y%m%d-%H%M%S)'
	ssh $(CACHYOS_HOST) 'cp $(CACHYOS_DST)/prometheus.yml   $(CACHYOS_DST)/prometheus.yml.bak-$$(date +%Y%m%d-%H%M%S)'
	scp -q $(PROM_DIR)/alert-rules.yml $(CACHYOS_HOST):$(CACHYOS_DST)/alert-rules.yml
	scp -q $(PROM_DIR)/prometheus.yml  $(CACHYOS_HOST):$(CACHYOS_DST)/prometheus.yml
	@echo "== Prometheus reload (SIGHUP via API) =="
	ssh $(CACHYOS_HOST) 'curl -fsS -X POST http://localhost:9090/-/reload && echo "  reload OK"'

deploy-cadvisor:
	@echo "== scp cadvisor compose → $(VPS_HOST) =="
	scp -q configs/monitoring/vps-cadvisor/docker-compose.yml $(VPS_HOST):$(VPS_CADV_DST)/docker-compose.yml
	ssh $(VPS_HOST) 'cd $(VPS_CADV_DST) && docker compose up -d'

## --- DRIFT ------------------------------------------------------------------

drift:
	@echo "== sha256: deploy ↔ Repo =="
	@diff_file() { \
		host="$$1"; remote="$$2"; local_f="$$3"; \
		r=$$(ssh "$$host" "sha256sum $$remote 2>/dev/null | awk '{print \$$1}'"); \
		l=$$(shasum -a 256 "$$local_f" | awk '{print $$1}'); \
		if [ "$$r" = "$$l" ]; then \
			echo "  [OK]    $$host:$$remote"; \
		else \
			echo "  [DRIFT] $$host:$$remote"; \
			echo "          repo=$$l  host=$$r"; \
		fi; \
	}; \
	diff_file $(CACHYOS_HOST) $(CACHYOS_DST)/alert-rules.yml $(PROM_DIR)/alert-rules.yml; \
	diff_file $(CACHYOS_HOST) $(CACHYOS_DST)/prometheus.yml  $(PROM_DIR)/prometheus.yml; \
	diff_file $(VPS_HOST)     $(VPS_CADV_DST)/docker-compose.yml configs/monitoring/vps-cadvisor/docker-compose.yml
