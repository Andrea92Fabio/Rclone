SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

CHART_DIR   ?= .
VALUES_FILE := $(CHART_DIR)/values.yaml
SCRIPTS     := $(CHART_DIR)/scripts

# Parametri sovrascrivibili da riga di comando, es.:  make clean-data CHECKERS=192
CHECKERS       ?=
TPS_LIMIT      ?=
DRY_RUN        ?= false
RECREATE       ?=
HELM_EXTRA     ?=

# Credenziali S3 da config.env (copia config.env.example). Il file NON va committato.
-include config.env
export

# Namespace, bucket e nome del Secret sono letti da values.yaml (unica fonte di verità).
NAMESPACE   := $(shell awk -F': *' '/^namespace:/ {gsub(/"/,"",$$2); print $$2}' $(VALUES_FILE))
BUCKET      := $(shell awk '/^target:/ {f=1; next} f && /^  bucket:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"')
SECRET_NAME := $(shell awk '/^secret:/ {f=1; next} f && /^  name:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"')

ifeq ($(strip $(NAMESPACE)),)
$(error ❌ Campo 'namespace' non trovato in $(VALUES_FILE))
endif
ifeq ($(strip $(BUCKET)),)
$(error ❌ Campo 'target.bucket' non trovato in $(VALUES_FILE))
endif
ifeq ($(strip $(SECRET_NAME)),)
$(error ❌ Campo 'secret.name' non trovato in $(VALUES_FILE))
endif

RUN     := bash $(SCRIPTS)/run-job.sh
CONFIRM := bash $(SCRIPTS)/confirm.sh

# Opzioni helm opzionali costruite dai parametri da riga di comando
OPTS := --set rclone.dryRun=$(DRY_RUN) \
	$(if $(CHECKERS),--set rclone.checkers=$(CHECKERS)) \
	$(if $(TPS_LIMIT),--set rclone.tpsLimit=$(TPS_LIMIT)) \
	$(HELM_EXTRA)

.PHONY: help guard secrets count clean-data purge status clean-jobs clean-all

help:
	@echo "Pulizia bucket '$(BUCKET)' (namespace '$(NAMESPACE)')"
	@echo ""
	@echo "  make count       conta oggetti e dimensione (sola lettura, consigliato per primo)"
	@echo "  make clean-data  SVUOTA il bucket (il bucket resta). Chiede conferma"
	@echo "  make purge       SVUOTA ed ELIMINA il bucket. Chiede conferma"
	@echo "  make status      stato di Job e release Helm"
	@echo "  make secrets     crea/aggiorna il Secret S3 da config.env"
	@echo "  make clean-jobs  ferma e rimuove le release Helm del cleaner"
	@echo "  make clean-all   come clean-jobs, e rimuove anche il Secret"
	@echo ""
	@echo "Opzioni:  CHECKERS=N  TPS_LIMIT=N  DRY_RUN=true  RECREATE=1"
	@echo "          CONFIRM_BUCKET=$(BUCKET)   (salta il prompt, per uso non interattivo)"
	@echo "          HELM_EXTRA=\"--set rclone.cleanupMultipartAge=\"\"\""

# Blocca i target se c'è già un Job attivo (cleaner o migrazione) nel namespace.
guard:
	@bash $(SCRIPTS)/guard.sh $(NAMESPACE)

# Idempotente (apply). Con RECREATE=1 cancella e ricrea il Secret.
secrets:
	@echo "--- Secret S3 '$(SECRET_NAME)' nel namespace '$(NAMESPACE)' ---"
	@for v in ACCESS_KEY SECRET_KEY; do \
		if [ -z "$${!v:-}" ]; then echo "❌ Variabile '$$v' non definita in config.env"; exit 1; fi; \
	done
	@if [ "$(RECREATE)" = "1" ]; then \
		kubectl delete secret $(SECRET_NAME) -n $(NAMESPACE) --ignore-not-found; \
	fi
	@kubectl create secret generic $(SECRET_NAME) -n $(NAMESPACE) \
		--from-literal=access_key_id="$$ACCESS_KEY" \
		--from-literal=secret_access_key="$$SECRET_KEY" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@echo "✓ Secret S3 aggiornato."

count: guard secrets
	@$(RUN) bucket-cleaner-count count $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Conteggio oggetti" $(OPTS)

clean-data: guard secrets
	@$(CONFIRM) $(BUCKET) "SVUOTAMENTO di tutti gli oggetti (il bucket resta)" || exit 1
	@$(RUN) bucket-cleaner-delete delete $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Svuotamento bucket" \
		--set target.confirmString="DELETE-$(BUCKET)-DATA" $(OPTS)

purge: guard secrets
	@$(CONFIRM) $(BUCKET) "ELIMINAZIONE TOTALE: oggetti + bucket" || exit 1
	@$(RUN) bucket-cleaner-purge purge $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Eliminazione totale bucket" \
		--set target.confirmString="PURGE-$(BUCKET)-PERMANENTLY" $(OPTS)

status:
	@kubectl get jobs -n $(NAMESPACE) -l app.kubernetes.io/name=bucket-cleaner
	@echo ""
	@helm list -n $(NAMESPACE) --filter '^bucket-cleaner-'

# Ferma anche i Job in corso (helm uninstall elimina i Pod).
clean-jobs:
	@echo "--- Rimozione release Helm del cleaner nel namespace '$(NAMESPACE)' ---"
	-@for r in bucket-cleaner-count bucket-cleaner-delete bucket-cleaner-purge; do \
		helm uninstall $$r -n $(NAMESPACE) >/dev/null 2>&1 && echo "  rimossa release $$r"; \
	done
	@echo "✓ Release e job puliti."

clean-all: clean-jobs
	-@kubectl delete secret $(SECRET_NAME) -n $(NAMESPACE) --ignore-not-found
	@echo "✓ Rimossi release Helm, Pod, Job e Secret S3 (bucket $(BUCKET))."
