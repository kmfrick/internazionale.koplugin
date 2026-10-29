# Internazionale per KOReader

Plugin per [KOReader](https://github.com/koreader/koreader) che scarica un numero di
[Internazionale](https://www.internazionale.it) e lo impagina come EPUB pensato per e-ink.
Serve un abbonamento: il plugin scarica i numeri con il tuo account di abbonato.

> Progetto personale e non ufficiale, senza alcun legame con Internazionale. Pensato per leggere
> sul proprio e-reader i numeri del proprio abbonamento.

Cosa c'è nell'EPUB:

- copertina e pagina di sommario con occhielli, titoli e autori, tutti cliccabili;
- indice di KOReader su tre livelli (sezione → sottosezione di Cultura → articolo), quindi le tacche
  dei capitoli nella barra di avanzamento coincidono con gli articoli;
- per ogni articolo: occhiello (sezione · tag), titolo, sommario, firma con testata e paese, foto con
  didascalia e crediti, capolettera, intertitoli, box, citazioni, recensioni brevi, rimando alla pagina
  cartacea e link "Torna al sommario";
- strisce, vignette e foto ad alta risoluzione (1200 px), illustrazioni a 640 px;
- metadati da serie (`Internazionale`, numero), quindi in KOReader i numeri si ordinano da soli.

## Stato

Scritto per KOReader v2026.07.1 su Kindle. Non usa niente di specifico del Kindle, quindi dovrebbe
funzionare anche su Kobo, PocketBook e simili, ma lì non è stato provato.
I test automatici coprono il parsing delle risposte del sito e la costruzione dell'EPUB;
l'interfaccia è nuova, quindi segnala pure i problemi aprendo una issue.

## Installazione

1. Copia la cartella `internazionale.koplugin` in `koreader/plugins/` sul dispositivo
   (sul Kindle è `/mnt/us/koreader/plugins/`).
2. Riavvia KOReader.
3. Menu **Strumenti → Internazionale → Account: accedi → Accedi…** con email e password del sito.

## Uso

**Strumenti → Internazionale**:

- **Ultimo numero**: scarica (se serve) e apre il numero in edicola.
- **Sfoglia i numeri**: gli ultimi 12 numeri più quelli già scaricati (in grassetto, con ✓).
  Tocca per aprire o scaricare; tieni premuto un numero scaricato per riscaricarlo o eliminarlo;
  "Altro numero…" apre un numero qualsiasi.
- **Immagini**: normali (~15 MB a numero), tutte in alta risoluzione, oppure solo strisce/vignette/foto.
- **Cartella**: dove salvare gli EPUB (predefinita: `<cartella home>/Internazionale`).

C'è anche l'azione **Internazionale: ultimo numero** da assegnare a un gesto
(Impostazioni → Gesti) o a una scorciatoia.

Un numero completo sono circa 95 articoli e 100 immagini: il download richiede qualche minuto.
Tocca il messaggio di avanzamento per interromperlo.

## Account e dati salvati

Il sito usa un token (JWT nel cookie `internaz_auth_tkn`) valido 7 giorni. Per rinnovarlo da solo,
il plugin salva email e password **in chiaro** in `koreader/settings/internazionale.lua` sul Kindle.
Se preferisci di no, usa **Account → Incolla un token…** con il valore del cookie copiato dal browser:
dovrai ripeterlo ogni settimana (se avevi già fatto l'accesso con la password, prima usa **Esci**).
**Account → Esci** cancella token, email e password salvati.

## Come funziona

Il plugin usa gli stessi endpoint del sito:

| Cosa | URL |
|---|---|
| pagina del numero (stream id, copertina) | `www.internazionale.it/sommario[/N]` |
| sommario strutturato | `data.internazionale.it/stream_data/items/sommario/200/<stream_id>/0.json` |
| articolo a blocchi | `data.internazionale.it/stream_data/item/article/<id>.json` |
| login | `POST api.internazionale.it/users/login/` con `{email, psw}` |

Come nel browser, le richieste a `*.internazionale.it` portano il cookie `internaz_auth_tkn`
dell'account (tranne il login, che lo ottiene). Il plugin non lo manda mai ad altri host, neanche
seguendo un redirect.

`internaz_api.lua` gestisce rete, login e parsing; `internaz_epub.lua` trasforma i blocchi
(`text`, `dropcap`, `image`, `infobox`, `minireview`, …) in XHTML e scrive l'EPUB man mano,
senza tenere le immagini in memoria; `main.lua` contiene l'interfaccia di KOReader.

Non inclusi: l'oroscopo (nel sommario è solo un link a un'altra pagina) e i box "leggi anche"
che rimandano ad articoli del sito.

## Test

Dalla cartella di una build di KOReader per Linux (`lib/koreader`), con il suo LuaJIT:

```bash
./luajit <repo>/tests/unit.lua <repo>/internazionale.koplugin [corpus]
read -rs INTERNAZ_TOKEN && export INTERNAZ_TOKEN   # incolla il token: così non resta nella history
./luajit <repo>/tests/live_smoke.lua <repo>/internazionale.koplugin   # poche richieste reali
./luajit <repo>/tests/build_issue.lua <repo>/internazionale.koplugin out.epub
python3 -I <repo>/tests/check_epub.py out.epub
```

`build_issue.lua` funziona anche offline: passa come terzo argomento una cartella con
`sommario.html`, `sommario.json`, `a_<id>.json`, `sample.jpg` e `sample.png` salvati in precedenza.
Tienila fuori dalla repo (`corpus/` è nel `.gitignore`): sono contenuti della rivista.

## Licenza

[GNU Affero General Public License v3.0](LICENSE) o successiva (AGPL-3.0-or-later).
