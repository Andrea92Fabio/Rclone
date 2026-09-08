# Variabili generali (parametri di tooling, non dati di migrazione)
CHART_DIR ?= .
VALUES_FILE := $(CHART_DIR)/values.yaml
WAIT_SCRIPT := bash scripts/wait-for-job.sh

# Includi il file di configurazione: contiene SOLO le credenziali S3
-include config.env
export

# ============================================================
# Timeout (in secondi) per l'attesa di test/check. Override da
# riga di comando, es: make check CHECK_TIMEOUT=60
# copy e sync NON hanno timeout: possono muovere grandi quantità
# di dati e restano in attesa fino a Complete o Failed del Job.
# ============================================================
TEST_TIMEOUT  ?= 180
CHECK_TIMEOUT ?= 300

# ============================================================
# Namespace: letto direttamente da values.yaml (il Makefile non
# lo genera/hardcoda da solo). Se manca, ci si ferma subito.
# ============================================================
NAMESPACE := $(shell awk -F': *' '/^namespace:/ {gsub(/"/,"",$$2); print $$2}' $(VALUES_FILE))
ifeq ($(strip $(NAMESPACE)),)
$(error ❌ Campo 'namespace' non trovato in $(VALUES_FILE). Verifica il file prima di procedere.)
endif

# ============================================================
# Credenziali: DEVONO arrivare da config.env, nessun default.
# ============================================================
REQUIRED_VARS := MINIO_ACCESS_KEY MINIO_SECRET_KEY GARAGE_ACCESS_KEY GARAGE_SECRET_KEY

$(foreach v,$(REQUIRED_VARS),$(if $(strip $($(v))),,$(error ❌ Variabile '$(v)' non definita in config.env. Controlla il file prima di procedere.)))

.PHONY: secrets test copy check sync clean

secrets:
	@echo "--- Rigenerazione Secret S3 ---"
	kubectl delete secret minio-source-credentials garage-dest-credentials -n $(NAMESPACE) --ignore-not-found
	kubectl create secret generic minio-source-credentials \
		--namespace=$(NAMESPACE) \
		--from-literal=access_key_id=$(MINIO_ACCESS_KEY) \
		--from-literal=secret_access_key=$(MINIO_SECRET_KEY)
	kubectl create secret generic garage-dest-credentials \
		--namespace=$(NAMESPACE) \
		--from-literal=access_key_id=$(GARAGE_ACCESS_KEY) \
		--from-literal=secret_access_key=$(GARAGE_SECRET_KEY)
	@echo "✓ Secret ricreati con successo nel namespace '$(NAMESPACE)'."

test: secrets
	@echo "--- Avvio Fase 1: Simulation (Dry-run) ---"
	-helm uninstall rclone-test -n $(NAMESPACE) --ignore-not-found
	helm install rclone-test $(CHART_DIR) -n $(NAMESPACE) \
		--set rclone.mode=copy \
		--set rclone.dryRun=true
	@echo "--- Attesa completamento Test ---"
	@$(WAIT_SCRIPT) rclone-test-rclone-migration-copy $(NAMESPACE) $(TEST_TIMEOUT); RC=$$?; \
	BUCKET_NAME=$$(awk '/^minio:/ {f=1; next} f && /^  bucket:/ {print $$2; exit} /^[^ ]/ {f=0}' $(VALUES_FILE) | tr -d '"'); \
	if [ $$RC -eq 0 ]; then \
		echo "" && echo "✅ TUTTO BENE: Test completato con successo per il bucket: $$BUCKET_NAME"; \
	elif [ $$RC -eq 2 ]; then \
		echo "" && echo "⏱️  TIMEOUT: il Job di test non si è concluso in tempo." && exit 1; \
	else \
		echo "" && echo "❌ ATTENZIONE: Il Job di test è fallito!" && exit 1; \
	fi

copy: secrets
	@echo "--- Avvio Fase 2: Bulk Copy ---"
	-helm uninstall rclone-copy -n $(NAMESPACE) --ignore-not-found
	-helm install rclone-copy $(CHART_DIR) -n $(NAMESPACE) \
		--set rclone.mode=copy \
		--set rclone.dryRun=false \
		--set rclone.ignoreErrors=true
	@echo "--- Attesa completamento Copia Massiva e streaming log ---"
	@kubectl logs -f -n $(NAMESPACE) -l app.kubernetes.io/instance=rclone-copy --tail=20 & \
	LOG_PID=$$!; \
	$(WAIT_SCRIPT) rclone-copy-rclone-migration-copy $(NAMESPACE) 0; RC=$$?; \
	kill $$LOG_PID 2>/dev/null || true; \
	if [ $$RC -eq 0 ]; then \
		echo "" && echo "✅ TUTTO BENE: Copia massiva completata con successo!"; \
	elif [ $$RC -eq 2 ]; then \
		echo "" && echo "⏱️  TIMEOUT: la copia massiva non si è conclusa in tempo." && exit 1; \
	else \
		echo "" && echo "⚠️  NOTA: La copia massiva ha riscontrato anomalie sui file sorgente (ignorate), procediamo."; \
	fi

sync: secrets
	@echo "--- Avvio Fase 4: Delta Sync Finale ---"
	-helm uninstall rclone-sync -n $(NAMESPACE) --ignore-not-found
	-helm install rclone-sync $(CHART_DIR) -n $(NAMESPACE) \
		--set rclone.mode=sync \
		--set rclone.dryRun=false \
		--set rclone.ignoreErrors=true
	@echo "--- Attesa completamento Sync Finale e streaming log ---"
	@kubectl logs -f -n $(NAMESPACE) -l app.kubernetes.io/instance=rclone-sync --tail=20 & \
	LOG_PID=$$!; \
	$(WAIT_SCRIPT) rclone-sync-rclone-migration-sync $(NAMESPACE) 0; RC=$$?; \
	kill $$LOG_PID 2>/dev/null || true; \
	if [ $$RC -eq 0 ]; then \
		echo "" && echo "✅ TUTTO BENE: Allineamento finale (Sync) completato con successo!"; \
	elif [ $$RC -eq 2 ]; then \
		echo "" && echo "⏱️  TIMEOUT: il Sync finale non si è concluso in tempo." && exit 1; \
	else \
		echo "" && echo "⚠️  NOTA: Il Sync finale ha riscontrato anomalie minori (ignorate)."; \
	fi

check: secrets
	@echo "--- Avvio Fase 3: Verification (Check) ---"
	-helm uninstall rclone-check -n $(NAMESPACE) --ignore-not-found
	helm install rclone-check $(CHART_DIR) -n $(NAMESPACE) \
		--set rclone.mode=check \
		--set rclone.backoffLimit=0
	@echo "--- Attesa completamento Verifica e streaming log ---"
	@kubectl logs -f -n $(NAMESPACE) -l app.kubernetes.io/instance=rclone-check --tail=20 & \
	LOG_PID=$$!; \
	$(WAIT_SCRIPT) rclone-check-rclone-migration-check $(NAMESPACE) $(CHECK_TIMEOUT); RC=$$?; \
	kill $$LOG_PID 2>/dev/null || true; \
	if [ $$RC -eq 0 ]; then \
		echo "" && echo "✅ TUTTO BENE: Nessuna differenza trovata tra i bucket!"; \
	elif [ $$RC -eq 2 ]; then \
		echo "" && echo "⏱️  TIMEOUT: la verifica non si è conclusa in tempo." && exit 1; \
	else \
		echo "" && echo "❌ ATTENZIONE: Rilevate differenze o problemi nella verifica!" && exit 1; \
	fi

clean:
	@echo "--- Pulizia risorse Helm e Secret nel namespace '$(NAMESPACE)' ---"
	-helm uninstall rclone-test -n $(NAMESPACE) --ignore-not-found
	-helm uninstall rclone-copy -n $(NAMESPACE) --ignore-not-found
	-helm uninstall rclone-check -n $(NAMESPACE) --ignore-not-found
	-helm uninstall rclone-sync -n $(NAMESPACE) --ignore-not-found
	kubectl delete secret minio-source-credentials garage-dest-credentials -n $(NAMESPACE) --ignore-not-found
	@echo "✓ Pulizia completata."