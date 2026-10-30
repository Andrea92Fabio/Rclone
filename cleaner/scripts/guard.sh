#!/usr/bin/env bash
# Rifiuta di proseguire se nel namespace c'e' gia' un Job attivo di bucket-cleaner
# o di rclone-migration (non si svuota un bucket mentre qualcuno ci sta copiando dentro).
#
# Uso:   guard.sh <namespace>
# Exit:  0 = nessun Job attivo, 1 = Job attivo o cluster non raggiungibile

set -uo pipefail

NS="${1:?Uso: $0 <namespace>}"

OUT=$(kubectl get jobs -n "$NS" -l 'app.kubernetes.io/name in (bucket-cleaner,rclone-migration)' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.active}{"\n"}{end}') || {
  echo "❌ Impossibile interrogare il cluster (kubectl get jobs -n $NS)." >&2
  exit 1
}

ACTIVE=$(printf '%s\n' "$OUT" | awk 'NF==2 && $2>0 {print $1}')

if [ -n "$ACTIVE" ]; then
  echo "❌ Job già in esecuzione nel namespace '$NS':" >&2
  printf '   %s\n' $ACTIVE >&2
  echo "   Attendi che termini, oppure fermalo con 'make clean-jobs' (bucket-cleaner) o 'make clean' (migrazione)." >&2
  exit 1
fi
