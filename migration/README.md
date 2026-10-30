# Rclone Migration Job

Chart Helm per migrare un bucket tra due storage compatibili S3 (MinIO, Garage, Ceph, AWS...) da una **sorgente** a una **destinazione**, con un Job Kubernetes che esegue `rclone`.
Pensato per bucket con milioni di oggetti piccoli, con gli applicativi ancora attivi durante la migrazione.

## Flusso consigliato

```sh
cp config.env.example config.env   # compila le 4 credenziali (una tantum)

make test       # 1. simulazione della copia, non scrive nulla
make copy       # 2. copia massiva (non cancella mai nulla)
make delta      # 3. (ripetibile) copia solo gli oggetti recenti, con le app ancora attive

# --- finestra di cutover: sospendere le scritture sugli applicativi ---
make delta      # 4. ultimo delta rapido
make sync-dry   # 5. simula il sync: controlla cosa verrebbe copiato e CANCELLATO
make sync       # 6. allinea la destinazione alla sorgente
make check      # 7. verifica finale (a scritture sospese)
```

`make help` mostra tutti i target. Ogni target installa una release Helm dedicata, segue i log e termina
con exit code diverso da 0 se il Job fallisce.

## Cosa fa ogni target

| Target | Release | Effetto |
|---|---|---|
| `test` | `rclone-test` | `copy --dry-run`: elenca cosa copierebbe |
| `copy` | `rclone-copy` | `copy` completo. Mai cancella dalla destinazione |
| `delta` | `rclone-delta` | `copy --max-age=AGE` (default `2h`): guarda solo gli oggetti recenti, senza listare la destinazione. Molto veloce |
| `sync-dry` | `rclone-sync-dry` | `sync --dry-run`: mostra cosa verrebbe copiato e cancellato |
| `sync` | `rclone-sync` | `sync --delete-after`: **cancella dalla destinazione** ciò che non esiste in sorgente |
| `check` | `rclone-check` | Confronta i due bucket in sola lettura |
| `status` | | Stato di Job e release |
| `secrets` | | Crea/aggiorna i Secret S3 da `config.env` (idempotente) |
| `clean` | | Ferma i Job in corso, rimuove release e Secret |

Opzioni da riga di comando:

```sh
make delta AGE=6h                          # finestra del delta
make sync MAX_DELETE=50000                 # limite di cancellazioni consentite
make check CHECK_DOWNLOAD=false            # check veloce: nome + dimensione/hash
make secrets RECREATE=1                    # cancella e ricrea i Secret (default: apply, senza finestre scoperte)
make copy HELM_EXTRA="--set rclone.tpsLimit=800 --set rclone.transfers=32"   # qualsiasi valore di values.yaml
```

## Protezioni integrate

- **Guard**: ogni target si rifiuta di partire se c'è già un Job rclone attivo (migrazione o `bucket-cleaner`). Evita di uccidere un upload
  a metà (oggetti e multipart orfani) e di lanciare due migrazioni sullo stesso bucket. Per fermare un Job: `make clean`.
- **`maxDelete`** (default 1000): il `sync` si ferma senza cancellare nulla se dovrebbe eliminare più oggetti.
  Se `sync-dry` mostra un numero atteso di cancellazioni maggiore, alza il limite con `MAX_DELETE=N` solo dopo
  aver verificato l'elenco.
- **`backoffLimit: 0`**: se il Pod muore non riparte da solo, perché un retry rifà tutto il lavoro e carica il backend.
  Si rilancia a mano.
- **Niente `--ignore-errors`**: i file spariti dalla sorgente durante la copia generano errori che vanno letti nei log.
- **`tpsLimit`** (default 400 richieste/s): limita il carico sugli storage di sorgente e destinazione per non penalizzare gli applicativi.
  Alzalo a piccoli passi (400 → 800 → 1200) guardando la latenza degli applicativi.
- **Template con validazione**: `rclone.mode` o `rclone.compare` non validi, o `maxAge` usato fuori da `copy`,
  fanno fallire `helm install` con un messaggio chiaro.

## Parametri principali (`values.yaml`)

| Parametro | Default | Significato |
|---|---|---|
| `rclone.compare` | `checksum` | `checksum`: confronta gli ETag già presenti nel listing (nessuna richiesta extra, rileva file riscritti con stessa dimensione; se l'hash non è confrontabile rclone ripiega sulla dimensione). `size-only`: solo dimensione. Usa `size-only` se `make test` vuole ricopiare quasi tutto (ETag non MD5, es. cifratura SSE) |
| `rclone.maxAge` | `""` | Solo `copy`: limita ai file recenti e attiva `--no-traverse` |
| `rclone.noTraverse` | `false` | `true` solo se la destinazione è vuota o quasi |
| `rclone.tpsLimit` / `tpsBurst` | `400` / `50` | Richieste HTTP al secondo (0 = illimitato) |
| `rclone.maxDelete` | `1000` | Solo `sync` (0 = nessun limite) |
| `rclone.checkDownload` | `true` | Solo `check`: `--download` confronta i byte |
| `rclone.transfers` / `checkers` | `16` / `32` | Parallelismo |
| `resources.limits.memory` | `6Gi` | Con `--fast-list` servono circa 1 GB ogni milione di oggetti |

Per `copy` e `sync` il chart passa anche `--s3-no-head`, `--s3-no-check-bucket` e `--s3-disable-checksum`
(meno richieste per oggetto). Per `check` questi flag **non** vengono usati, così la verifica resta rigorosa.

## Cosa verifica `make check`

Con `CHECK_DOWNLOAD=true` (default) rclone legge ogni oggetto da entrambi i lati e confronta i byte.
Il Job termina `Complete` solo se ogni oggetto della sorgente esiste nella destinazione, nessun oggetto della destinazione manca in sorgente
e i contenuti sono identici.

**Non sono verificati**: cartelle vuote, metadati (content-type, metadata utente), ACL, tag, versioni precedenti.

Perché il risultato sia valido: nessuno deve scrivere su sorgente o destinazione durante il check, va lanciato dopo
`make sync`, e il Job deve concludersi in `Complete` (un timeout non è una conferma).

Costo: legge tutto da entrambi i lati, due GET per oggetto. Con `tpsLimit: 400` e 1,5M oggetti servono circa
2 ore: per un check lungo puoi alzare il limite a finestra di cutover chiusa
(`HELM_EXTRA="--set rclone.tpsLimit=1500"`), oppure usare `CHECK_DOWNLOAD=false` per un controllo rapido.

## Prerequisiti

- `kubectl` sul cluster giusto, `helm` 3, `make`, `bash`.
- Namespace di `values.yaml` già presente; `endpoint`, `provider` e `region` di `source` e `destination` in `values.yaml` adatti ai tuoi storage; endpoint raggiungibili dal Pod.
- `config.env` con le credenziali (vedi `config.env.example`; `debug.yaml` è un Pod di utilità, escluso dal chart da `.helmignore`). Non va committato (è in `.gitignore` e `.helmignore`).
  Evita `#` e `$` nei valori. Se le credenziali sono state condivise o pubblicate, ruotale a fine migrazione.
- I nomi dei Secret vengono letti dal Makefile da `source.secretName` e `destination.secretName` di `values.yaml`.
- `config.env` usa `SRC_ACCESS_KEY`, `SRC_SECRET_KEY`, `DST_ACCESS_KEY`, `DST_SECRET_KEY`.

## Controllo manuale

```sh
make status
kubectl logs -n garage -l app.kubernetes.io/instance=rclone-copy -f
kubectl describe job -n garage -l app.kubernetes.io/instance=rclone-copy
helm lint .
helm template rclone-copy . --set rclone.mode=copy     # mostra gli argomenti rclone effettivi
```

Installazione senza Makefile (i Secret vanno creati prima):

```sh
helm install rclone-copy . -n garage --set rclone.mode=copy --set rclone.dryRun=false
```

## Problemi comuni

- **Il Job va in `OOMKilled`**: alza `resources.limits.memory` (circa 1 GB per milione di oggetti con `--fast-list`).
- **Lento**: con oggetti piccoli il limite è il numero di richieste, non la banda. Alza `tpsLimit` e poi `transfers`
  a piccoli passi; controlla CPU e disco dei metadata della destinazione.
- **`make test` vuole ricopiare quasi tutto** anche se i dati sono già presenti: gli ETag non sono MD5,
  passa a `compare: size-only`.
- **`sync` si ferma per `max-delete`**: nella destinazione ci sono più oggetti extra del limite. Ispeziona l'output di
  `make sync-dry` prima di alzare `MAX_DELETE`.
- **Oggetti o multipart orfani dopo interruzioni**: `rclone backend cleanup dst:BUCKET -o max-age=1h`
  da un Pod con lo stesso remote configurato.
