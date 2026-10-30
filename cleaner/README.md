# Bucket Cleaner (S3 generico)

Chart Helm che esegue un Job Kubernetes con `rclone` per **contare**, **svuotare** o **eliminare** un bucket su qualsiasi storage compatibile S3 (Garage, MinIO, Ceph, AWS...).
Pensato per bucket con milioni di oggetti (testato sul dimensionamento per ~1,5M).

## Flusso consigliato

```sh
cp config.env.example config.env   # compila ACCESS_KEY e SECRET_KEY (una tantum)

make count        # 1. quanti oggetti ci sono (sola lettura)
make clean-data   # 2. svuota il bucket, il bucket resta (chiede conferma)
make purge        # 3. oppure: svuota ed elimina il bucket (chiede conferma)
```

`make help` mostra tutti i target. Ogni target installa una release Helm, segue i log e termina con exit code
diverso da 0 se il Job fallisce.

## Cosa fa ogni modalità

| Target | Release | Effetto |
|---|---|---|
| `count` | `bucket-cleaner-count` | `rclone size`: conta oggetti e byte. Non modifica nulla |
| `clean-data` | `bucket-cleaner-delete` | conta, pulisce i multipart orfani, cancella tutti gli oggetti, **verifica che il bucket sia vuoto** |
| `purge` | `bucket-cleaner-purge` | come `clean-data`, poi elimina il bucket e **verifica che non esista più** |
| `status` | | Stato di Job e release |
| `secrets` | | Crea/aggiorna il Secret S3 da `config.env` (idempotente) |
| `clean-jobs` | | Ferma i Job in corso e rimuove le release |
| `clean-all` | | Come `clean-jobs`, e rimuove anche il Secret |

Il Job è `Complete` solo se la verifica finale passa: se restano oggetti, fallisce e va rilanciato.

Opzioni da riga di comando:

```sh
make clean-data CHECKERS=192            # più parallelismo nelle cancellazioni
make clean-data TPS_LIMIT=1000          # limita le richieste/s se lo storage è condiviso
make clean-data DRY_RUN=true            # simulazione (una riga di log per oggetto: pesante con 1,5M oggetti)
make clean-data CONFIRM_BUCKET=cardinalis-prod   # salta il prompt (uso non interattivo)
make clean-data HELM_EXTRA='--set rclone.cleanupMultipartAge='   # salta la pulizia multipart
```

## Protezioni integrate

- **Conferma a terminale**: `clean-data` e `purge` chiedono di digitare il nome del bucket.
- **`confirmString` nel template**: `helm install` fallisce se la stringa non corrisponde a `DELETE-<bucket>-DATA`
  (svuotamento) o `PURGE-<bucket>-PERMANENTLY` (eliminazione). Il Makefile la imposta da solo dopo la conferma.
- **Guard**: ogni target si rifiuta di partire se nel namespace c'è già un Job `bucket-cleaner` **o** `rclone-migration`
  attivo, così non si svuota un bucket mentre una migrazione ci scrive. Per fermare un Job: `make clean-jobs`.
- **`backoffLimit: 0`**: nessun retry automatico del Pod; si rilancia a mano.
- **Verifica finale** dentro il Job: un'operazione incompleta non risulta mai "tutto bene".
- **Validazione nel template**: `target.mode` non valido o `confirmString` errata bloccano `helm install`.

## Prestazioni (1,5M oggetti)

`rclone` cancella un oggetto per richiesta, in parallelo: la velocità dipende da `rclone.checkers` (default 128),
non dalla banda. I tempi reali dipendono dal carico e dal disco dei metadata dello storage, quindi sono da misurare:
lancia prima `make count`, poi `make clean-data` e guarda la riga di progresso ogni 30 s.

- Alza `CHECKERS` a piccoli passi (128 → 192 → 256) guardando CPU e latenza dello storage.
- Il log è volutamente sintetico (`verbose: false`): con `-v` si scrive una riga per oggetto.
- Con `--fast-list` servono circa 1 GB di RAM per milione di oggetti: i limiti di default (4Gi) coprono fino a ~3M.
- Su alcuni storage (es. Garage) lo spazio disco non scende subito: i blocchi sono liberati dopo dal garbage collector.

## Prerequisiti

- `kubectl` sul cluster giusto, `helm` 3, `make`, `bash`.
- Namespace di `values.yaml` già presente; `endpoint`, `s3.provider` e `s3.region` in `values.yaml` adatti al tuo storage; endpoint raggiungibile dal Pod.
- `config.env` con le credenziali (vedi `config.env.example`). Non va committato (è in `.gitignore` e `.helmignore`).
  Non scrivere credenziali reali nel README o in altri file versionati.
- La chiave S3 deve avere permessi di lettura e scrittura sul bucket. Per `purge` serve anche il permesso
  *owner* sul bucket; se `rmdir` viene negato, svuota con `clean-data` ed elimina il bucket con gli strumenti di amministrazione dello storage (es. Garage: `garage bucket delete --yes <bucket>`).

## Controllo manuale

```sh
make status
kubectl logs -n garage -l app.kubernetes.io/instance=bucket-cleaner-delete -f
helm lint .
helm template bucket-cleaner-count . --set target.mode=count    # mostra lo script del Job
```

## Problemi comuni

- **Il Job va in `OOMKilled`**: alza `resources.limits.memory` (circa 1 GB per milione di oggetti con `--fast-list`).
- **Verifica fallita ("restano N oggetti")**: probabilmente c'è qualcuno che scrive sul bucket, o alcuni delete
  sono andati in errore: leggi i log e rilancia `make clean-data`.
- **`purge` non elimina il bucket**: vedi i permessi nei prerequisiti.
- **Lento**: alza `CHECKERS`, poi controlla CPU e disco dello storage; non alzare `TPS_LIMIT` se è un limite voluto.
