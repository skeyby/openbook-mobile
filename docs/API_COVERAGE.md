# Copertura del contratto REST

La fonte autorevole è il documento OpenAPI upstream. La revisione verificata dal client, con hash del contenuto ed elenco delle operazioni, è conservata in [api-baseline.json](api-baseline.json). Per confrontarla con una specifica aggiornata usare `Scripts/check_api.py`, passando `--spec` se necessario.

Le API restano sperimentali; verificare che l’istanza scelta le esponga.

## Funzionalità dell’app

Tutti i percorsi REST sotto `/rest/v1`; OAuth e discovery alla radice.

| Operazioni | Copertura |
| --- | --- |
| POST /oauth/register, POST /oauth/token | Registrazione client pubblico, Authorization Code/PKCE, rinnovo serializzato |
| GET /instance | Nome nella home; icona e descrizione lette dal modello ma volutamente non visualizzate |
| GET /me | Identità autenticata e presentazione del proprio profilo |
| GET /me/posts | Solo post propri pubblicati, paginazione per pubblicazione e after |
| GET /persons/{personId} | Profilo navigabile da autore, UUID, relazioni e richieste ricevute |
| GET /persons/{personId}/followers e /following | Liste con scroll infinito e cursore personId |
| GET/PUT/DELETE /persons/{personId}/follow | Stato in uscita none/pending/accepted, segui e annullamento |
| GET /me/follow-requests | Richieste ricevute dal solo account autenticato, scroll infinito |
| PATCH/DELETE /me/follow-requests/{personId} | Approvazione con followStatus=accepted o rifiuto; solo 204 conferma |
| GET /posts, GET /persons/{personId}/posts | Timeline/Mondo e post/condivisioni degli altri profili; Link validati per la sorgente |
| GET /posts/{postId} | Dettaglio e rilettura di reazioni/conteggi |
| POST /posts, PATCH/DELETE /posts/{postId} | Creazione testuale con visibilità, modifica basilare e cancellazione dei propri post |
| PUT/DELETE /posts/{postId}/like e /announce | Like e rilanci manuali, stato condiviso con i dettagli |

## Limiti e possibilità future

- GET `/.well-known/oauth-authorization-server` è documentato ma non viene interrogato: il client usa i percorsi OAuth documentati dell’istanza. L’eventuale discovery richiede una validazione dedicata delle destinazioni prima di trasmettere credenziali.
- ETag/If-None-Match non usati: le letture chiedono rappresentazioni complete senza cache privata persistente. Retry-After non avvia attese o tentativi automatici.
- Il contratto non aggiunge ricerca per nome, commenti, modifica profilo, gestione di richieste rivolte a comunità o rimozione di follower già accettati. DELETE di una richiesta non è un comando per rimuovere un follower.
- Creazione/modifica di media, quote e sondaggi non sono esposte da questi input. I post possono contenere risorse non ancora rappresentate dal modello; gli errori server restano autorevoli.
- I test automatici usano trasporto simulato. Il successo dei test non dimostra il funzionamento su una particolare istanza: seguire la [guida di verifica](VALIDATION.md) per il collaudo interattivo.
