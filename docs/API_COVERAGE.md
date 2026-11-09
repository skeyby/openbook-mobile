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
| GET /posts/{postId}/comments | Tutti i livelli di risposta, ordine asc, thread annidati, scroll infinito e Link validato |
| POST /posts/{postId}/comments | Testo e parent opzionale, senza upload o audience separata |
| GET /posts/{postId}/comments/{commentId} | Rilettura autorevole prima della modifica |
| PATCH /posts/{postId}/comments/{commentId} | Solo testo del proprio commento, preservando allegati e parent |
| DELETE /posts/{postId}/comments/{commentId} | Cancellazione propria confermata solo con 204; risposte conservate |
| POST /posts, PATCH/DELETE /posts/{postId} | Creazione JSON testuale o multipart multimediale; modifica basilare e cancellazione dei propri post |
| GET /postPublication/{postPublicationId} | Monitoraggio owner-only della pubblicazione differita, senza avviare elaborazioni |
| DELETE /postPublication/{postPublicationId} | Annullamento di invii pending/failed con conferma; solo 204 è successo |
| PUT/DELETE /posts/{postId}/like e /announce | Like e rilanci manuali, stato condiviso con i dettagli |

## Limiti e possibilità future

- GET `/.well-known/oauth-authorization-server` è documentato ma non viene interrogato: il client usa i percorsi OAuth documentati dell’istanza. L’eventuale discovery richiede una validazione dedicata delle destinazioni prima di trasmettere credenziali.
- ETag/If-None-Match non usati: le letture chiedono rappresentazioni complete senza cache privata persistente. Retry-After non avvia attese o tentativi automatici.
- Il contratto non aggiunge ricerca per nome, modifica profilo, gestione di richieste rivolte a comunità o rimozione di follower già accettati. DELETE di una richiesta non è un comando per rimuovere un follower.
- Upload foto/video implementato per nuovi post su iOS; selezione audio, upload commenti e modifica allegati non implementati. Quote e sondaggi non sono esposti da questi input. I post possono contenere risorse non ancora rappresentate dal modello; gli errori server restano autorevoli.
- I test automatici usano trasporto simulato. Il successo dei test non dimostra il funzionamento su una particolare istanza: seguire la [guida di verifica](VALIDATION.md) per il collaudo interattivo.

## Commenti ed email verificata

Il modello Comment include post radice, parent nullable, autore, testo, date, lingua, emoji, allegati, contatori e interazione di like. La lista comprende risposte di ogni livello; i genitori mancanti non implicano che le risposte vadano nascoste. Le conversazioni federate possono essere parziali. Il cursore after deve restare pubblicato nello stesso post: 422 richiede un riavvio, senza ricostruire il cursore. page/cursor/afterAt non sono ammessi.

Letture e scritture richiedono l’account attivo e accesso al post. Conversazioni private escluse, creazione su post direct non supportata. Scritture di modifica/cancellazione riservate ai propri commenti locali; nessun privilegio aggiuntivo per amministratori. Le risposte 201/200 confermano la persistenza locale, non la consegna federata. GET condizionali non usati: nessuna cache privata persistente o If-None-Match senza una rappresentazione conservata.

ProblemDetails.code è opzionale. Il client riconosce emailVerificationRequired su 403 e mantiene la bozza, sia per POST /posts sia per POST /posts/{postId}/comments. Dopo la conferma email resta utilizzabile lo stesso Bearer. Il requisito non viene esteso a letture, follow, like/rilanci o modifica/cancellazione commenti.

I contatori e commentLiked sono leggibili, ma non ci sono operazioni per cambiare il like di un commento. Nessun pulsante di like azionabile viene inventato.

Il supporto ai commenti viene verificato tramite GET prima di esporre le azioni. Istanze precedenti che rispondono 405/501, oppure 404 con post ancora leggibile, ricevono un messaggio di indisponibilità e nessun comando di creazione/risposta. Il controllo è locale al dettaglio, recuperabile con refresh e distinto da errori temporanei o accesso negato; non assume che un singolo 404 significhi incompatibilità di tutta l’istanza.

## Upload post e pubblicazioni differite

POST /posts accetta JSON solo testuale senza postAttachments, oppure multipart/form-data: parte post JSON senza filename e parti file riferite una volta ciascuna tramite NewPostAttachment.filePart. L’ordine dell’array determina la presentazione. mediaAltText è opzionale/nullable e limitato a 1000 caratteri; l’app permette una descrizione per file. Testo esattamente vuoto ammesso solo con allegati, soli spazi sempre rifiutati. GET /instance espone instanceUploadLimits: maxAttachmentsPerPost, maxAttachmentBytes, maxVideoAttachmentBytes e maxRequestBytes. Il client verifica quantità, limite per tipo e dimensione multipart completa prima dell’invio. Valori assenti o non validi significano zero allegati; maxVideoAttachmentBytes null disabilita i video, maxRequestBytes null non impone un tetto totale dichiarato. Il server resta autorevole per formati, durata e limiti infrastrutturali inferiori.

201 conferma pubblicazione locale; 202 conferma solo ricezione dell’intero invio per elaborazione differita. PostPublication espone id distinto dal post, stato pending/processing/failed/published e postId nullable. Location validato per origine e percorso; mai usato liberamente come destinazione Bearer. Uno stato 202 illeggibile resta accettato e non genera reinvio. Il client può recuperare l’id da una Location sicura; senza riferimento affidabile invita a controllare la timeline.

GET dello stato non avvia/riprova l’elaborazione. Monitoraggio solo in foreground; errori fermano il polling fino a retry esplicito. DELETE è disponibile solo per pending/failed; processing restituisce 409, published/assente/altrui restituisce 404. Nessun retry di scrittura, privilegio staff o equivalenza con DELETE del post. I record terminali sono soggetti alla retention del server (sette giorni predefiniti), senza cancellare il post finale. 404 durante il monitoraggio non dimostra annullamento o pubblicazione riusciti.
