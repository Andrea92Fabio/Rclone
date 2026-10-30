#!/usr/bin/env bash
# Chiede conferma a terminale prima di un'operazione distruttiva.
# Bisogna digitare esattamente il nome del bucket.
# In modo non interattivo si puo' passare CONFIRM_BUCKET=<bucket> nell'ambiente.
#
# Uso:   confirm.sh <bucket> <descrizione-operazione>
# Exit:  0 = confermato, 1 = annullato

set -uo pipefail

BUCKET="${1:?Uso: $0 <bucket> <descrizione>}"
WHAT="${2:-operazione distruttiva}"

if [ "${CONFIRM_BUCKET:-}" = "$BUCKET" ]; then
  exit 0
fi

echo ""
echo "⚠️  STAI PER ESEGUIRE: ${WHAT}"
echo "    Bucket: ${BUCKET}"
echo "    L'operazione NON è reversibile."
echo ""
printf "Per confermare digita il nome del bucket: "
read -r ANSWER || ANSWER=""

if [ "$ANSWER" != "$BUCKET" ]; then
  echo "Annullato: il nome digitato non corrisponde." >&2
  exit 1
fi
