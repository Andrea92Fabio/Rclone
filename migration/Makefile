SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

CHART_DIR   ?= .
VALUES_FILE := $(CHART_DIR)/values.yaml
SCRIPTS     := $(CHART_DIR)/scripts

# Parametri sovrascrivibili da riga di comando, es.:  make delta AGE=6h
AGE            ?= 2h
MAX_DELETE     ?=
CHECK_DOWNLOAD ?= true
CHECK_CHECKERS ?= 48
HELM_EXTRA     ?=
RECREATE       ?=

# Credenziali S3 da config.env (copia config.env.example). Il file NON va committato.
-include config.env
export

# Namespace e bucket sono letti da values.yaml (unica fonte di verità).
NAMESPACE := $(shell awk -F': *' '/^namespace:/ {gsub(/"/,"",$$2); print $$2}' $(VALUES_FILE))
BUCKET    := $(shell awk '/^source:/ {f=1; next} f && /^  bucket:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"')

ifeq ($(strip $(NAMESPACE)),)
$(error ❌ Campo 'namespace' non trovato in $(VALUES_FILE))
endif
SRC_SECRET := $(shell awk '/^source:/ {f=1; next} f && /^  secretName:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"')
DST_SECRET := $(shell awk '/^destination:/ {f=1; next} f && /^  secretName:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"')

ifeq ($(strip $(BUCKET)),)
$(error ❌ Campo 'source.bucket' non trovato in $(VALUES_FILE))
endif
ifeq ($(strip $(SRC_SECRET))$(strip $(DST_SECRET)),)
$(error ❌ Campi 'source.secretName' / 'destination.secretName' non trovati in $(VALUES_FILE))
endif

RUN := bash $(SCRIPTS)/run-job.sh

.PHONY: help guard secrets test copy delta sync-dry sync check status clean-job clean-all

help:
	@echo "Migrazione bucket '$(BUCKET)' (namespace '$(NAMESPACE)')"
	@echo ""
	@echo "  make test       simulazione della copia (--dry-run), non scrive nulla"
	@echo "  make copy       copia massiva sorgente -> destinazione (non cancella nulla)"
	@echo "  make delta      copia solo gli oggetti recenti (AGE=$(AGE)); veloce, ripetibile con le app attive"
	@echo "  make sync-dry   simula il sync finale: mostra cosa verrebbe copiato/CANCELLATO"
	@echo "  make sync       sync finale: allinea la destinazione alla sorgente e CANCELLA gli extra sulla destinazione"
	@echo "  make check      verifica finale (CHECK_DOWNLOAD=true: byte per byte, lento)"
	@echo "  make status     stato di Job e release Helm"
	@echo "  make secrets    crea/aggiorna i Secret S3 da config.env (RECREATE=1: cancella e ricrea)"
	@echo "  make clean-job  ferma e rimuove le release Helm (i Job); i Secret restano"
	@echo "  make clean-all  come clean-job, e rimuove anche i Secret S3"
	@echo ""
	@echo "Opzioni:  AGE=6h  MAX_DELETE=N  CHECK_DOWNLOAD=false  CHECK_CHECKERS=N  RECREATE=1"
	@echo "          HELM_EXTRA=\"--set rclone.tpsLimit=800 --set rclone.transfers=32\""

# Blocca i target se c'è già un Job rclone attivo (evita upload interrotti e job doppi).
guard:
	@bash $(SCRIPTS)/guard.sh $(NAMESPACE)

# Idempotente (apply): nessuna finestra senza credenziali. Con RECREATE=1 cancella e ricrea i Secret.
secrets:
	@for v in SRC_ACCESS_KEY SRC_SECRET_KEY DST_ACCESS_KEY DST_SECRET_KEY; do \
		if [ -z "$${!v:-}" ]; then echo "❌ Variabile '$$v' non definita in config.env"; exit 1; fi; \
	done
	@if [ "$(RECREATE)" = "1" ]; then \
		kubectl delete secret $(SRC_SECRET) $(DST_SECRET) -n $(NAMESPACE) --ignore-not-found; \
	fi
	@kubectl create secret generic $(SRC_SECRET) -n $(NAMESPACE) \
		--from-literal=access_key_id="$$SRC_ACCESS_KEY" \
		--from-literal=secret_access_key="$$SRC_SECRET_KEY" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@echo "  ✓ $(SRC_SECRET)"
	@kubectl create secret generic $(DST_SECRET) -n $(NAMESPACE) \
		--from-literal=access_key_id="$$DST_ACCESS_KEY" \
		--from-literal=secret_access_key="$$DST_SECRET_KEY" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@echo "  ✓ $(DST_SECRET)"
	@echo "✓ Secret S3 aggiornati nel namespace '$(NAMESPACE)'."

test: guard secrets
	@$(RUN) rclone-test copy $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Simulazione copia (dry-run)" \
		--set rclone.dryRun=true $(HELM_EXTRA)

copy: guard secrets
	@$(RUN) rclone-copy copy $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Copia massiva" \
		--set rclone.dryRun=false $(HELM_EXTRA)

delta: guard secrets
	@$(RUN) rclone-delta copy $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Copia delta (ultimi $(AGE))" \
		--set rclone.dryRun=false --set rclone.maxAge=$(AGE) $(HELM_EXTRA)

# ATTENZIONE: il sync cancella dalla destinazione ciò che non esiste in sorgente.
# Protezione: si ferma se deve cancellare più di rclone.maxDelete oggetti (values.yaml, o MAX_DELETE=N).
sync-dry: guard secrets
	@$(RUN) rclone-sync-dry sync $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Simulazione sync finale (dry-run)" \
		--set rclone.dryRun=true $(if $(MAX_DELETE),--set rclone.maxDelete=$(MAX_DELETE)) $(HELM_EXTRA)

sync: guard secrets
	@$(RUN) rclone-sync sync $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Sync finale" \
		--set rclone.dryRun=false $(if $(MAX_DELETE),--set rclone.maxDelete=$(MAX_DELETE)) $(HELM_EXTRA)

# Da lanciare DOPO il sync e a scritture sospese. Sola lettura, ripetibile.
check: guard secrets
	@$(RUN) rclone-check check $(NAMESPACE) $(CHART_DIR) $(BUCKET) "Verifica (check)" \
		--set rclone.checkDownload=$(CHECK_DOWNLOAD) --set rclone.checkers=$(CHECK_CHECKERS) $(HELM_EXTRA)

status:
	@kubectl get jobs -n $(NAMESPACE) -l app.kubernetes.io/name=rclone-migration
	@echo ""
	@helm list -n $(NAMESPACE) --filter '^rclone-'

# Ferma anche i Job in corso (helm uninstall elimina i Pod). I Secret restano.
clean-job:
	@echo "--- Rimozione release Helm nel namespace '$(NAMESPACE)' ---"
	-@for r in rclone-test rclone-copy rclone-delta rclone-sync-dry rclone-sync rclone-check; do \
		helm uninstall $$r -n $(NAMESPACE) >/dev/null 2>&1 && echo "  rimossa release $$r"; \
	done
	@echo "✓ Release e Job rimossi (bucket $(BUCKET))."

# Come clean-job, e in piu' rimuove i Secret S3.
clean-all: clean-job
	-@kubectl delete secret $(SRC_SECRET) $(DST_SECRET) -n $(NAMESPACE) --ignore-not-found
	@echo "✓ Rimossi anche i Secret S3."