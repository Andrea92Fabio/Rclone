#!/usr/bin/env bash
# Attende che un Job Kubernetes raggiunga lo stato Complete o Failed.
#
# A differenza di `kubectl wait --for=condition=complete`, questo script
# si accorge anche se il Job FALLISCE (condition Failed=True) e si ferma
# subito, invece di restare bloccato fino al timeout.
#
# Uso:   wait-for-job.sh <job-name> <namespace> [timeout-seconds]
#        timeout-seconds = 0 (o omesso) -> nessun timeout, attende indefinitamente
# Exit:  0 = Job Complete
#        1 = Job Failed
#        2 = Timeout raggiunto senza esito

set -uo pipefail

JOB_NAME="$1"
NAMESPACE="$2"
TIMEOUT="${3:-3600}"
INTERVAL=2
ELAPSED=0

while [ "$TIMEOUT" -eq 0 ] || [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  COMPLETE=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
  FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)

  if [ "$COMPLETE" = "True" ]; then
    exit 0
  fi
  if [ "$FAILED" = "True" ]; then
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

exit 2