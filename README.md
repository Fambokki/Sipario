# Sipario

Il tuo "Netflix" personale per iPhone: incolli il link di una libreria di film e serie e Sipario la trasforma in un catalogo con copertine, generi, stagioni, episodi, "Continua a guardare" e "La mia lista".

> Sipario non contiene né fornisce contenuti: mostra e riproduce solo le librerie che aggiungi tu. Usa librerie di video che possiedi o che hai il diritto di guardare.

## Cosa puoi importare

| Sorgente | Esempio |
|---|---|
| **Playlist M3U / M3U8** | Usa nome, copertina (`tvg-logo`) e categoria (`group-title`). I nomi con `S01E02` o `1x02` diventano episodi raggruppati per serie e stagione. |
| **Catalogo JSON** | Film e serie con stagioni, trame, generi e immagini (formato sotto). |
| **Cartella web** | Il link a una cartella che elenca i file (es. il server web di un NAS): Sipario esplora fino a 5 livelli di sottocartelle, riconosce `Serie/`, `Stagione 1/`, `Season 2/` e usa `poster.jpg` / `folder.jpg` come copertina. |
| **Singolo video** | Link diretto a `.mp4`, `.mov`, `.m4v` o a un flusso HLS `.m3u8`. |

Si possono aggiungere più librerie: compaiono tutte insieme nella Home e si aggiornano da sole ogni 6 ore.

### Formato JSON

```json
{
  "name": "La mia videoteca",
  "movies": [
    { "title": "Inception", "year": 2010, "poster": "https://…/poster.jpg",
      "genres": ["Azione"], "url": "https://…/inception.mp4" }
  ],
  "series": [
    { "title": "Dark", "year": 2017,
      "seasons": [ { "season": 1, "episodes": [
        { "episode": 1, "title": "Segreti", "url": "https://…/dark-s01e01.mp4" } ] } ] }
  ]
}
```

Campi facoltativi: `year`, `poster`, `backdrop`, `overview`, `genres`, `tmdb` (id della scheda), `still` per gli episodi. Va bene anche un semplice elenco `[ … ]` di elementi con `"type": "movie" | "series" | "live"`.

## Copertine e schede (consigliato)

Con una chiave gratuita di [TMDB](https://www.themoviedb.org/settings/api) (Impostazioni → *Copertine e schede*) Sipario abbina i titoli alle schede ufficiali: locandine, sfondi, loghi, trame in italiano, generi, cast, trailer e titoli degli episodi. Se una scheda è sbagliata, nel menu `…` del titolo puoi toglierla.

## Riproduzione

- Riprende da dove eri rimasto, passa da solo all'episodio successivo, supporta Picture in Picture e AirPlay.
- Il player di iOS legge MP4, MOV, M4V e HLS. Per MKV, AVI e altri formati Sipario propone di aprire il video in **VLC** o **Infuse**.

## Compilazione e installazione (senza Mac)

Ogni `push` su `main` avvia GitHub Actions, che compila l'app. `Sipario.ipa` è in **Releases**.
Si installa con Sideloadly dal PC Windows; con un Apple ID gratuito va reinstallata ogni 7 giorni (i dati restano).

## Struttura

| File | Cosa fa |
|---|---|
| `Sipario/Importer.swift` | Lettura di M3U, JSON, cartelle web; riconoscimento di film, serie, stagioni ed episodi dai nomi |
| `Sipario/LibraryStore.swift` | Librerie, archivio su disco, aggiornamenti, avanzamento, la mia lista, abbinamento TMDB |
| `Sipario/TMDB.swift` | Schede, immagini, loghi, cast, episodi |
| `Sipario/Playback.swift` | Player, ripresa, episodio successivo, apertura in VLC/Infuse |
| `Sipario/Views/` | Home, Film, Serie TV, Cerca, La mia lista, scheda, impostazioni |
