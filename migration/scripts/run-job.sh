#!/usr/bin/env bash
# Installa una release Helm del chart, segue i log e attende l'esito del Job.
#
# Uso:   run-job.sh <release> <mode> <namespace> <chart-dir> <bucket> <descrizione> [argomenti helm...]
# Esempio:
#   run-job.sh rclone-copy copy mio-namespace . cardinalis-prod "Copia" --set rclone.dryRun=false
#
# Exit:  0 = Job Complete
#        1 = Job Failed o errore di installazione
#        2 = timeout (non usato con timeout 0, mantenuto per coerenza con wait-for-job.sh)

set -uo pipefail

if [ $# -lt 6 ]; then
  echo "Uso: $0 <release> <mode> <namespace> <chart-dir> <bucket> <descrizione> [argomenti helm...]" >&2
  exit 64
fi

RELEASE="$1"; MODE="$2"; NS="$3"; CHART="$4"; BUCKET="$5"; LABEL="$6"
shift 6
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- ${LABEL} (release: ${RELEASE}, bucket: ${BUCKET}) ---"

# Rimuove una release precedente con lo stesso nome (il guard del Makefile ha già
# verificato che non ci siano Job attivi).
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true

if ! helm install "$RELEASE" "$CHART" -n "$NS" --set rclone.mode="$MODE" "$@" >/dev/null; then
  echo "❌ helm install fallito per la release ${RELEASE}." >&2
  exit 1
fi

# Il nome del Job dipende dagli helper del chart: lo si legge dal cluster.
JOB=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  JOB=$(kubectl get jobs -n "$NS" -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$JOB" ] && break
  sleep 1
done
if [ -z "$JOB" ]; then
  echo "❌ Job non trovato dopo l'installazione della release ${RELEASE}." >&2
  exit 1
fi
echo "Job: ${JOB}"

# Segue i log; riprova finché il Pod non è avviato. Si ferma quando il Pod termina.
(
  until kubectl logs -f "job/${JOB}" -n "$NS" --tail=20 2>/dev/null; do
    sleep 3
  done
) &
LOG_PID=$!

SECONDS=0
"$HERE/wait-for-job.sh" "$JOB" "$NS" 0
RC=$?

sleep 3
pkill -P "$LOG_PID" 2>/dev/null || true
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

DUR="$((SECONDS / 60))m$((SECONDS % 60))s"
echo ""
if [ "$RC" -eq 0 ]; then
  echo "✅ TUTTO BENE: ${LABEL} completato per il bucket ${BUCKET} (durata ${DUR})."
  exit 0
fi

echo "---- ultime righe di log ----"
kubectl logs "job/${JOB}" -n "$NS" --tail=25 2>/dev/null || true
echo ""
if [ "$RC" -eq 2 ]; then
  echo "⏱️  TIMEOUT: ${LABEL} non si è concluso in tempo (bucket ${BUCKET})." >&2
else
  echo "❌ ATTENZIONE: ${LABEL} fallito per il bucket ${BUCKET} (durata ${DUR})." >&2
  echo "   Log completi: kubectl logs -n ${NS} -l app.kubernetes.io/instance=${RELEASE}" >&2
fi
exit 1
