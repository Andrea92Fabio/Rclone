CHART_DIR ?= .

# Carica automaticamente le credenziali da config.env
-include config.env
export

.PHONY: help secrets clean-data purge clean-jobs clean-all
.DEFAULT_GOAL := help

help:
	@echo "=== Gestione S3 Bucket Cleaner ==="
	@echo "Uso: make [target]"
	@echo ""
	@echo "Target disponibili:"
	@echo "  secrets    - Sincronizza i Secret S3 in Kubernetes leggendo da config.env e values.yaml"
	@echo "  clean-data - Svuota i file nel bucket configurato in values.yaml"
	@echo "  purge      - Elimina completamente il bucket e i file configurati in values.yaml"
	@echo "  clean-jobs - Pulisce le release Helm residue"
	@echo "  clean-all  - Rimuove tutto: release Helm, pod, job e i Secret S3 dal cluster"
	@echo ""

# Estrae namespace, secret name e bucket in modo pulito da values.yaml senza dipendere da yq
NAMESPACE := $(shell awk '/^namespace:/ {print $$2}' values.yaml | tr -d '"' | tr -d "'")
SECRET_NAME := $(shell awk '/^  name:/ {print $$2; exit}' values.yaml | tr -d '"' | tr -d "'")
BUCKET := $(shell awk '/^  bucket:/ {print $$2; exit}' values.yaml | tr -d '"' | tr -d "'")

secrets:
	@echo "--- Sincronizzazione Secret S3 '$(SECRET_NAME)' nel namespace '$(NAMESPACE)' ---"
	-kubectl delete secret $(SECRET_NAME) -n $(NAMESPACE) --ignore-not-found
	kubectl create secret generic $(SECRET_NAME) \
		--namespace=$(NAMESPACE) \
		--from-literal=access_key_id='$(shell echo $(BUCKET_ACCESS_KEY) | tr -d "'" | tr -d '"')' \
		--from-literal=secret_access_key='$(shell echo $(BUCKET_SECRET_KEY) | tr -d "'" | tr -d '"')'
	@echo "✓ Secret configurati."

clean-data: secrets
	@echo "--- Svuotamento dati del bucket '$(BUCKET)' nel namespace '$(NAMESPACE)' ---"
	-helm uninstall bucket-cleaner -n $(NAMESPACE) --ignore-not-found
	helm install bucket-cleaner $(CHART_DIR) \
		--namespace $(NAMESPACE) --create-namespace \
		--set target.mode=delete \
		--set target.confirmString="DELETE-$(BUCKET)-DATA"
	@echo "Attesa avvio ed esecuzione del job..."
	@kubectl wait --for=condition=complete job/bucket-cleaner-bucket-cleaner-delete -n $(NAMESPACE) --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=failed job/bucket-cleaner-bucket-cleaner-delete -n $(NAMESPACE) --timeout=5s 2>/dev/null || true
	@echo "Recupero log finali..."
	kubectl logs job/bucket-cleaner-bucket-cleaner-delete -n $(NAMESPACE) --tail=-1
	@echo "Pulizia release Helm..."
	helm uninstall bucket-cleaner -n $(NAMESPACE)

purge: secrets
	@echo "--- Eliminazione TOTALE del bucket '$(BUCKET)' nel namespace '$(NAMESPACE)' ---"
	-helm uninstall bucket-cleaner -n $(NAMESPACE) --ignore-not-found
	helm install bucket-cleaner $(CHART_DIR) \
		--namespace $(NAMESPACE) --create-namespace \
		--set target.mode=purge \
		--set target.confirmString="PURGE-$(BUCKET)-PERMANENTLY"
	@echo "Attesa avvio ed esecuzione del job..."
	@kubectl wait --for=condition=complete job/bucket-cleaner-bucket-cleaner-purge -n $(NAMESPACE) --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=failed job/bucket-cleaner-bucket-cleaner-purge -n $(NAMESPACE) --timeout=5s 2>/dev/null || true
	@echo "Recupero log finali..."
	kubectl logs job/bucket-cleaner-bucket-cleaner-purge -n $(NAMESPACE) --tail=-1
	@echo "Pulizia release Helm..."
	helm uninstall bucket-cleaner -n $(NAMESPACE)

clean-jobs:
	@helm uninstall bucket-cleaner -n $(NAMESPACE) 2>/dev/null || true
	@echo "✓ Release pulite."

clean-all:
	@echo "--- Pulizia totale di risorse e secret nel namespace '$(NAMESPACE)' ---"
	-helm uninstall bucket-cleaner -n $(NAMESPACE) --ignore-not-found
	-kubectl delete secret $(SECRET_NAME) -n $(NAMESPACE) --ignore-not-found
	@echo "✓ Rimossi release Helm, Pod e Secret S3 con successo."