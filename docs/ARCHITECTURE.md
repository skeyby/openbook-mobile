# Architettura

## Scelte

SwiftUI permette di condividere schermate tra iPhone, iPad e Mac. Un unico target Xcode genera l’app nativa per iOS e macOS; il modulo `OpenBookCore` raccoglie modelli, composizione URL, OAuth e trasporto HTTP. Nessuna dipendenza esterna o generazione automatica dei modelli in questa fase: il contratto è piccolo e sperimentale.

`AppStore`, isolato al MainActor, gestisce accesso, ripristino dal Portachiavi, rinnovo serializzato e disconnessione locale. Le viste chiedono credenziali valide prima delle letture. CredentialRenewal serializza il rinnovo nel Core: gli errori OAuth definitivi invalid_grant/invalid_client/unauthorized_client e i rifiuti 401 del token endpoint bloccano altri tentativi fino a una nuova sessione. AppStore rimuove le credenziali dal Portachiavi e mostra la necessità di accedere nuovamente, conservando schermata e bozza in memoria fino alla disconnessione esplicita; un client_id dichiarato non valido viene rimosso dalle preferenze. Errori temporanei di rete/5xx/429 non invalidano la sessione e restano riprovabili. Reset, cancellazione e identificativo del task impediscono che risultati della vecchia sessione salvino o invalidino quella nuova. Il client usa URLSession asincrona con timeout, senza cache persistente o cookie, e restituisce errori HTTP conservandone lo status. Errori Problem Details vengono presentati come testo.

Il flusso di accesso registra una volta un client pubblico per istanza, genera verifier e state crittograficamente casuali, apre il browser di sistema e verifica la callback prima dello scambio. I token si salvano solo dopo una risposta valida. La chiave del Portachiavi non viene sincronizzata su altri dispositivi. Il client ID, pubblico, viene salvato in UserDefaults.

Le letture persone partono sempre dall’origine configurata. Per i post i link di paginazione vengono seguiti solo dopo averne validato origine, percorso, sorgente e ordinamento. Per le persone si ricostruisce la richiesta con il cursore personId. Non vengono seguiti redirect HTTP con credenziali. Immagini profilo e copertine sono richieste separatamente da AsyncImage senza Bearer token. Come punto di partenza si mantengono le politiche automatiche di Apple: nessuna cache immagini custom, TTL/FIFO o capacità impostata dall’app. Da iOS/macOS 27 AsyncImage documenta caching HTTP automatico secondo gli header del server; sulle versioni precedenti non si garantisce lo stesso riuso. Il client API autenticato mantiene invece la propria sessione effimera senza cache persistente.

## Contratto attuale

Revisione del contratto verificata: hash, versione dichiarata ed elenco operazioni in [api-baseline.json](api-baseline.json). Usare il controllo API per confrontare la specifica upstream corrente.

- OAuth: `/oauth/register`, `/oauth/authorize`, `/oauth/token`. Il percorso authorize è descritto nello schema di sicurezza, non come operazione separata.
- Utente autenticato: `/rest/v1/me`, oggetto Me con myPerson. Lo stesso PersonView carica questo risultato oppure il profilo UUID richiesto, senza dedurre l’identità dal token.
- Profili: `/rest/v1/persons/{personId}`.
- Feed: `/rest/v1/posts`, array diretto Post. Timeline richiede engine=timeline, sort=postTimelineAt e direction=desc; Mondo engine=world e sort=postPublishedAt. La continuazione segue il Link rel="next" del server, preservando i parametri: Timeline necessita di after e afterAt insieme. Il client valida stessa origine, percorso, engine e ordine prima di usare il link.
- Connessioni: suffissi `/followers` e `/following`, array di PersonReference e paginazione `after`, `limit`, `sort`, `direction`.
- Il documento espone anche metadata OAuth. Per questa prima versione si usano i percorsi definiti nel contratto; non si aggiunge discovery dinamica di endpoint remoti.
- Gli account application, feed e group restano visibili senza filtri aggiuntivi. Conteggi null/mancanti compaiono come “Non disponibile”; zero rimane zero.

## Creazione di post testuali

POST /rest/v1/posts invia un NewPost con postContent e postVisibility (public/unlisted/followers), senza proprietà aggiuntive. Il testo viene preservato; è validato localmente solo il requisito di contenuto non vuoto. Il limite dell’istanza resta a carico del server e gli errori 422 vengono mostrati usando anche i messaggi per campo di Problem Details.

PostComposer è un modello osservabile al MainActor, mantenuto dalla home per conservare la bozza mentre l’utente controlla la timeline. NewPostView presenta editor e visibilità, blocca modifiche e invii doppi durante la richiesta, richiede conferma di scarto e non salva il testo su disco. Una pubblicazione confermata cancella la bozza e ricrea il feed Timeline dalla prima pagina, senza inserire il post nel feed Mondo.

La creazione non è idempotente. Non ci sono retry automatici: errori di rete/5xx e successi inattesi diventano esiti incerti, bloccando il normale invio finché l’utente non sceglie esplicitamente di riprovare. È disponibile la chiusura per controllare la timeline senza perdere il testo. Le risposte 4xx sono presentate come rifiuti con bozza modificabile. HTTP 201 conferma la pubblicazione locale, non la consegna federata; anche se il corpo non è decodificabile l’app tratta il post come pubblicato e invita a controllare il feed invece di reinviarlo.

## Liste post condivise: home e profili

PostSource distingue feed Timeline/Mondo e feed di persona. APIClient.posts(source:) condivide composizione delle richieste, decodifica e gestione dei Link; il wrapper posts(engine:) rimane disponibile. La validazione della pagina impone origine, percorso e contesto della sorgente. I profili usano GET /persons/{personId}/posts senza engine/limit, con sort=postTimelineAt e direction=desc, seguendo after e afterAt esattamente come restituiti.

PostFeed contiene l’unica macchina di caricamento/paginazione e PostListView l’unica lista con trigger di fine pagina, vuoti/errori/retry e sincronizzazione di like/modifiche. La presentazione del profilo viene inserita come intestazione nella stessa List; il refresh rilegge prima il profilo e poi la prima pagina. I caricamenti duplicati sono ignorati; le cancellazioni non producono errori UI; 401/403/404 rimuovono le righe caricate. Errori temporanei mantengono post e cursore per il retry esplicito.

Il server restituisce post scritti e announce selezionati del profilo, senza garantire un archivio remoto completo. Non si filtrano autori diversi dal profilo: sono condivisioni legittime. Le azioni di scrittura rimangono basate sull’autore originale, non sul profilo da cui si sta navigando. Tombstone e overlay condivisi valgono in tutte le liste; cancellare l’ultima riga visibile produce lo stato vuoto quando non restano altre pagine.

AppNavigation e AppRoute centralizzano tutte le destinazioni nel NavigationStack della home: profili, post, ricerca, follower/seguiti e migrazioni. PostRow naviga con lo stesso router in ogni contesto; nel dettaglio l’apertura del dettaglio è disabilitata per evitare una route ricorsiva. La sorgente mantiene il proprio stato tornando indietro. I modelli delle liste e del dettaglio riusano il client di rete della sessione.

## Dettaglio del post

La nuvoletta del contatore commenti in PostRow apre la route Post nel NavigationStack della home, conservando stato e posizione del feed. I link Markdown rimangono indipendenti e non sono coperti da un gesto sull’intero testo. Per i post con avviso ancora chiuso è disponibile anche Apri dettaglio, senza rivelare prima il contenuto.

PostDetail carica GET /posts/{postId}, senza inventare un endpoint commenti e senza usare la voce del feed come sostituto della risposta. La risorsa non ha contesto announce/timeline. PostDetailView riusa PostRow per contenuto, autore, like e gestione dei propri post; nel dettaglio la nuvoletta è solo un contatore. Sotto al post c’è una sezione Commenti che descrive la funzionalità futura, senza dichiarare che l’elenco sia vuoto.

Le revisioni di PostLikes e PostManagement proteggono dalle letture del dettaglio precedenti a una modifica. Un post eliminato nella sessione resta non disponibile anche in questa schermata. Errori di caricamento rimuovono il vecchio contenuto e offrono Riprova; annullamento e richieste duplicate non avviano ulteriori letture. Il ritorno usa il back nativo iOS e BackNavigation su macOS; anche i profili aperti dal dettaglio restano nello stesso stack.

## Modifica e cancellazione dei propri post

AppStore carica l’identità con /me e invalida l’ID al cambio di sessione. Le azioni di gestione sono esposte soltanto quando coincide con postAuthor.personId; il contesto announce e i ruoli descrittivi non autorizzano azioni sull’originale.

PostEditor rilegge GET /posts/{postId} prima di compilare testo e visibilità, blocca salvataggi invariati/vuoti e invia solo le proprietà mutate di PatchPost. La modifica mantiene titolo/CW/lingua, gestiti dal server. Allegati, luogo e audience non supportate noti disabilitano l’editor; eventuali altre limitazioni del server restituiscono 409 senza modifiche. Rilettura e abbandono di una bozza richiedono conferma. Un fallimento non sostituisce il contenuto visualizzato.

PostManagement serializza PATCH e DELETE per post e conserva in memoria le risposte di modifica e le tombstone dei post eliminati. Gli overlay vengono applicati preservando postTimelineAt e postAnnounce della voce feed; revisioni e generazioni di sessione impediscono a risposte precedenti di annullare le modifiche o contaminare altri account. DELETE richiede conferma UI e si considera riuscita solo con 204 senza corpo. 404 e altri errori sono segnalati, senza dichiarare la cancellazione. Nessun retry automatico.

## Like

PUT e DELETE su `/rest/v1/posts/{postId}/like` sono idempotenti e non restituiscono JSON (PUT 201 o 204, DELETE 204). Il client separa validazione HTTP e decodifica del corpo. Dopo la scrittura legge GET /posts/{postId}: il dettaglio ritorna Post senza contesto timeline/announce e viene usato solo per aggiornare reazione e conteggio, senza sostituire il post del feed.

PostLikes, osservabile e isolato al MainActor, condivide stato/errori e richiesta attiva per post tra le sorgenti. Il pulsante disabilitato impedisce invii doppi. Nessun aggiornamento ottimistico dei conteggi. Dopo una scrittura confermata, in attesa della lettura, lo stato è noto ma il conteggio è indisponibile; se la lettura fallisce il retry ripete solo GET. Un errore di scrittura conserva lo stato precedente. Un contatore di revisione impedisce a risposte feed precedenti di sovrascrivere reazioni più recenti. Il cambio sessione cancella gli stati e invalida i risultati in volo.

## Limiti deliberati

Una sola sessione attiva. Timeline, selezionata inizialmente, è il feed dell’utente e comprende le condivisioni pertinenti. Mondo è il feed pubblico remoto già disponibile nell’istanza. Un menu dropdown nel titolo cambia sorgente; TimelineFeed è identificata dall’engine, così stato, cursore e scroll ripartono e il task della vecchia sorgente viene cancellato. Nessuna ricerca per nome o modifica del profilo: mancano i rispettivi endpoint. Il menu apre il proprio profilo, la ricerca UUID e la disconnessione. Autori e risultati di ricerca portano ai dettagli nello stesso stack; tornare indietro conserva i post caricati e lo stato della lista.

TimelineView serializza i caricamenti, mantiene visibile il trigger di fine lista durante la richiesta e segue solo link di pagina validati per la sorgente corrente. PostTimeline conserva ordine server e link successivo, elimina duplicati e interrompe la continuazione su pagina vuota/link già visto. Una pagina fallita lascia visibili i post già caricati e propone retry o ricaricamento iniziale (utile per HTTP 422 se il riferimento non è più disponibile); HTTP 401/403 cancella i dati visibili. Il refresh sostituisce il feed solo dopo una risposta valida.

I post presentano autore navigabile, data locale, titolo/testo, immagini, link agli altri media, luogo, pulsanti Mi piace e Rilancia e nuvoletta per il dettaglio. Il content warning nasconde anche media e fonte fino alla rivelazione. Non sono implementati sondaggi, quote o scritture diverse da like, rilanci e creazione/modifica/cancellazione dei propri post. Il testo dei post usa PostMarkdown, che interpreta il Markdown tramite AttributedString di Foundation e ne espone i blocchi a MarkdownPostView. SwiftUI applica il layout per titoli, liste anche annidate, citazioni, separatori e codice, conservando gli stili inline e le interruzioni di riga. I blocchi di codice scorrono orizzontalmente e non trasformano il proprio contenuto in link. I collegamenti relativi sono risolti rispetto a postUri; sono apribili solo HTTP, HTTPS e mailto, senza credenziali negli URL web. I collegamenti si aprono con il gestore di sistema, senza aggiungere Bearer token. Il rilevamento automatico delle email viene disattivato per le code delle menzioni @utente@dominio, che restano testo invece di link mailto. Il parser non usa WebView o HTML e non carica immagini Markdown automaticamente: rende il testo alternativo un link esplicito, mentre le immagini degli allegati mantengono AsyncImage. Il rendering è creato solo quando il content warning è rivelato. Le biografie rimangono testo sorgente per Markdown/HTML, con emoji del profilo renderizzate tramite CustomEmojiText. Anche titolo e Markdown dei post usano lo stesso helper con postCustomEmojis, dopo la rivelazione del CW. Le tabelle Markdown non hanno ancora un layout tabellare dedicato.

La specifica ora include esempi validi di post World e Timeline, registrati nei fixture dei test. Post decodifica anche postTimelineAt e il contesto opzionale postAnnounce: l’autore originale resta distinto da chi ha condiviso, il cui nome apre il relativo profilo.
Nessuna cache condizionale ETag in questa fase: ogni richiesta legge dal server. Le API possono cambiare anche senza un cambio di versione: la verifica SHA-256 serve a richiamare una revisione umana del contratto, non certifica automaticamente la compatibilità semantica.

Il rinnovo avviene prima della scadenza dichiarata. Un 401 non genera tentativi automatici: può indicare revoca o indisponibilità dell’account e richiede un nuovo accesso. Un 429 viene mostrato senza retry automatici; non è ancora implementata un’attesa guidata da Retry-After.

Prima di una distribuzione servono una prova completa con il server, verifica su simulatore/dispositivo, identità definitiva dell’app, icona, signing e configurazione di distribuzione. Non sono parte del bootstrap locale.

## Nome dell’istanza

APIClient.instanceMetadata legge GET /rest/v1/instance con Bearer e decodifica InstanceMetadata: nome, dominio, URL, descrizione e icona opzionale. AppStore mantiene i metadati soltanto in memoria, li azzera al cambio sessione e ignora risultati di sessioni precedenti. Caricamento iniziale e refresh della home sono indipendenti dal successo della timeline: un errore del branding usa l’host di accesso come fallback e consente retry esplicito dal menu. Il nome vuoto usa lo stesso fallback. Nessun caricamento dell’icona o rendering della descrizione.

instanceUrl e instanceDomain sono metadati: non cambiano l’origine delle richieste o la destinazione del Bearer. Non memorizziamo ETag né inviamo If-None-Match, quindi chiediamo sempre una rappresentazione completa; un 304 inatteso viene trattato come errore senza decodificare il corpo vuoto. Nessuna cache persistente o riutilizzo tra account.

Follower e seguiti usano il medesimo PeopleView: un indicatore di fondo con task identificato dal cursore carica la pagina successiva senza pulsanti. Il trigger resta montato durante la richiesta; loading serializza i caricamenti. ID duplicati e cursori già visti vengono eliminati, una pagina vuota ferma la continuazione. Errori sospendono il caricamento automatico e offrono retry esplicito; refresh riparte dalla prima pagina. La cancellazione della vista viene controllata prima e dopo la richiesta.

## Rilanci manuali

PostAnnounces è lo stato condiviso e osservabile delle reazioni manuali di rilancio. Il toggle legge postDirectAnnounced, distinto dal generico postAnnounced e dal contesto di provenienza postAnnounce. PUT /posts/{postId}/announce (201/204) e DELETE (204) non inviano né decodificano body. Dopo la conferma GET /posts/{postId} fornisce stato e conteggio autorevoli; una quote implicita può mantenere postAnnounced e il conteggio anche dopo DELETE. In caso di errore della rilettura lo stato confermato resta visibile, il conteggio diventa indisponibile e il retry esegue solo GET.

Le letture da feed e dettaglio vengono integrate con revisione, impedendo a letture precedenti di sovrascrivere mutazioni più recenti; il reset invalida i task della sessione precedente. Una sola mutazione per post; nessun retry automatico o modifica ottimistica dei conteggi. PostRow condivide azioni, errori e stato in ogni contesto. Nuovi rilanci disabilitati per audience diverse da public/unlisted; la rimozione manuale rimane disponibile. Le restrizioni non esposte nel modello (comunità private, sospensioni) vengono validate dal server. I cursori e il contesto announce del feed rimangono quelli letti: un refresh rilegge l’ordine aggiornato.

## Post del profilo autenticato

PostSource.mine usa GET /rest/v1/me/posts con sort=postPublishedAt, direction=desc e limit=20. PersonView sceglie questa sorgente dal menu Il mio profilo e quando il profilo aperto corrisponde all’identità autenticata nota. Gli altri profili mantengono PostSource.person. L’identità del PostListView dipende dalla sorgente: nessun riutilizzo di cursori fra /me/posts e /persons/{id}/posts.

La collezione personale include solo post pubblicati dall’utente, anche ristretti, di comunità e quote; esclude rilanci altrui, messaggi privati ed eliminati. Non ha postTimelineAt/postAnnounce. Segue il Link rel=next senza ricostruirlo, validando origine, percorso, sort/direction e parametri ammessi (after, limit, sort, direction); afterAt ed engine vengono rifiutati. Un 422 mantiene i post visibili e consente Ricarica dall’inizio. Il resto di PostFeed/PostListView/PostRow è condiviso, incluse reazioni e gestione dei propri post.

## Follow dei profili

APIClient.follow legge GET /persons/{personId}/follow con Bearer; none è un risultato 200, non un 404. PUT senza body accetta 200/201 con Follow (pending/accepted), DELETE accetta solo 204 e produce none. Gli stati futuri letti vengono conservati come stringhe e non abilitano il toggle. Nessun header condizionale o cache persistente.

PersonFollows mantiene stato, errore e richiesta attiva per persona normalizzata, serializzando GET e mutazioni nello stesso store di sessione. Generazione invalidata su disconnessione/cambio account. La scrittura usa l’identità Bearer; nessun body o identità agente fornita dal profilo. Si impedisce localmente self-follow e si attendono identità e stato noti. Pending e accepted portano entrambi a DELETE; non si deduce l’accettazione dal tipo account o dal campo di approvazione. Errori e risposte PUT illeggibili invalidano lo stato locale: il recupero esegue GET prima di consentire altre scritture, senza retry automatico di PUT che potrebbe reinviare richieste pending. Anche una lettura fallita cancella lo stato precedente; 404 non viene interpretato come none.

PersonView visualizza il controllo sotto la presentazione solo per profili altrui riconosciuti. Caricamento iniziale e refresh aggiornano relazione e profilo; il fallimento del follow non impedisce la lettura dei post. Dopo una mutazione confermata si rilegge il profilo per conteggi autorevoli. Le restrizioni di comunità e account sospesi/inattivi restano validate dal server.

## Richieste ricevute

IncomingFollowRequests separa le richieste in ingresso dalle relazioni in uscita PersonFollows. Lo store condiviso di sessione carica GET /me/follow-requests con limit=20, sort=personId, direction=asc e after=ultimo personId. Per questa collezione di persone il client ricostruisce la richiesta sulla stessa origine, usando solo il segnale Link rel=next. Non inoltra Bearer agli URL del Link. Deduplica gli ID, si ferma su cursore già visto o pagina vuota, conserva il cursore anche quando la relativa riga viene approvata/rifiutata: il contratto non richiede che il riferimento sia ancora nella collezione.

AppRoute.followRequests apre FollowRequestsView dallo stesso stack del proprio profilo, anche quando riconosciuto tramite UUID. Richiedenti navigabili, Indietro nativo iOS/esplicito macOS, refresh, stati vuoto/errore e caricamento progressivo. Una revisione di pagina risveglia il trigger anche se il refresh mantiene lo stesso cursore.

Letture e decisioni sono serializzate. PATCH invia solo followStatus=accepted, DELETE non ha corpo; nessuna decodifica per le risposte 204. Solo dopo conferma viene rimossa la riga. Non aggiorniamo ottimisticamente i conteggi dei follower né la relazione inversa in PersonFollows. Errori di decisione, anche 404 per richiesta già ritirata/gestita, bloccano altre scritture finché una ricarica esplicita riesce. Errori 401/403 cancellano i dati visibili. Reset e generazione impediscono risultati da sessioni precedenti. Nessun retry automatico e nessuna gestione per account diversi o comunità.

## Visualizzatore degli allegati immagine

PostRow e PersonView conservano una selezione locale PostImageSelection e presentano PostImageViewer tramite imageViewer(selection:). Il dettaglio profilo rende cliccabile l’avatar solo con URL HTTP/HTTPS valida senza credenziali; usa la foto restituita dall’API senza ricostruire URL di risoluzioni diverse. Il segnaposto senza foto resta decorativo. Su iOS fullScreenCover, su macOS sheet; la stessa card serve home, profili e dettaglio. La selezione contiene URL originale validato (o anteprima valida come fallback) e alt text. L’anteprima è un Button con stile plain, separato dalla navigazione al post; nessun caricamento dell’originale fino al tocco. Il content warning continua a controllare l’intero postBody, incluse anteprime e pulsante di apertura.

PostImageViewer usa AsyncImage senza credenziali API e aspect-fit nei limiti della finestra, su sfondo nero. Lo swipe discendente verticale chiude dopo una distanza sufficiente o un gesto rapido; i trascinamenti brevi tornano al centro rispettando Reduce Motion. X fissa nei margini sicuri, escape VoiceOver ed Esc permettono l’uscita alternativa. Caricamento ed errore con retry esplicito. ImageZoom contiene solo geometria CoreGraphics: scala 1×–6×, ancoraggio del punto iniziale del pinch e offset limitati al rettangolo dell’immagine effettivamente adattata, escludendo le bande nere. MagnifyGesture e DragGesture simultanei gestiscono pinch e pan; un pinch, anche quando termina a 1×, non viene convertito in chiusura. Doppio tocco 1×/3×, azione regolabile e ripristino per VoiceOver. I limiti si aggiornano dopo rotazione/ridimensionamento. Nessuna galleria, salvataggio su Foto o nuovo endpoint.

## Emoji personalizzate condivise tra profili e post

CustomEmoji, senza dipendenze UI, divide il testo in segmenti letterali e immagini solo per i codici presenti nella mappa passata dal chiamante (personAttributes.personCustomEmojis o postCustomEmojis). La variante AttributedString conserva gli attributi dei frammenti Markdown; ignora codice inline e link, compresi gli alt delle immagini Markdown, per preservarne comportamento e accessibilità. I blocchi di codice continuano a usare il rendering letterale. Preserva maiuscole, Unicode, spazi e ritorni a capo; accetta chiavi con i due punti e alias senza, dando precedenza alla forma esplicita. Codici sconosciuti o URL non web/con credenziali rimangono testo. URL unici nell’ordine di comparsa, senza scaricare il resto della mappa.

CustomEmojiText ricompone un singolo Text SwiftUI con immagini inline, anziché HStack o righe artificiali: ritorni a capo e baseline restano nel layout nativo. Dimensioni emoji adattate a Dynamic Type, label VoiceOver con shortcode per ogni immagine e selezione del testo nei campi già selezionabili. Applicato a nome, biografia ed etichette/valori dei campi in PersonView, titolo e blocchi Markdown di PostRow. Grassetto, corsivo, barrato e link del testo rimangono intatti. Le biografie restano letterali per Markdown/HTML.

Per inserire immagini raster dentro Text, il caricamento usa URLSession con politiche HTTP/cache di sistema, senza cookie, credenziali o Bearer; nessuna cache custom su disco. Solo thumbnail decodificate nello stato della vista: fino a 32 URL unici per testo, 4 download contemporanei, massimo 2 MiB per immagine con interruzione della richiesta fuori limite. ImageIO produce thumbnail da 128 px, primo fotogramma anche per GIF. Errori, formati non decodificabili e immagini oltre il budget mantengono il codice letterale; nessun retry automatico continuo. Task cancellati al cambio testo/uscita vista.

PersonReference non contiene una mappa emoji: autori, nomi dei rilanci e liste persone restano letterali. Non si fa una richiesta profilo per ogni riga e non si usa postCustomEmojis per interpretare i nomi degli autori.

## Date dei post

PostTimestamp applica una politica di sola presentazione: tempo relativo numerico italiano con unità intere trascorse, da “Adesso” a secondi/minuti/ore, per età inferiore a 24 ore. Da 24 ore in poi e per timestamp futuri usa data e ora nel fuso del dispositivo. PostRow condivide PostDateText tra home, profili e dettaglio. Una TimelineView SwiftUI con sequenza lazy si risveglia solo al prossimo cambio di unità visibile (secondo, minuto, ora), inclusa la soglia delle 24 ore, poi termina gli aggiornamenti. Nessun refresh API e nessuna modifica alle stringhe originali usate nei cursori.

I metadati dei post (data e stato di modifica) sono elementi testuali separati dal pulsante autore. Il pulsante espone nome, handle e suggerimento di navigazione; la sua etichetta non sostituisce i metadati per VoiceOver.
