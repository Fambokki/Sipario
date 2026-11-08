# Sipario

Il tuo cinema personale su iPhone, in stile Netflix, che mette insieme tre mondi:

- **Catalogo completo** (TMDB): film e serie del momento, schede con trailer, cast, stagioni ed episodi, e **dove guardarli in Italia** (Netflix, Prime Video, Disney+, NOW, Apple TV+…). Un tocco apre il titolo nell'app del servizio.
- **Il tuo server Jellyfin**: i tuoi film e le tue serie con "Continua a guardare", prossimi episodi, Picture in Picture e AirPlay. Se un titolo del catalogo è anche sul tuo server compare il pulsante **Riproduci**.
- **Classici gratuiti** (Internet Archive): film di pubblico dominio (noir, fantascienza, horror, western, cinema muto, cartoni d'epoca) da guardare subito dentro l'app.

In più: **"Stasera cosa guardo?"** (il dado in Home) pesca un titolo a caso in base all'umore, solo tra i tuoi abbonamenti, solo dal tuo server o da tutto. E c'è **La mia lista** per salvare titoli da qualunque fonte.

> Uso personale, non va sull'App Store. Riproduce solo contenuti legali: per i servizi a pagamento ti porta nella loro app.

## Primo avvio

1. **Chiave TMDB (gratis)** — registrati su [themoviedb.org](https://www.themoviedb.org/signup), poi *Impostazioni → API* e crea una chiave per uso personale. In Sipario: ingranaggio → incolla la chiave (va bene sia la "Chiave API" sia il "Token di lettura") → *Salva e verifica*.
2. **I miei abbonamenti** — sempre nelle Impostazioni, spunta i servizi che hai: compariranno righe dedicate in Home e il badge "Incluso nel tuo abbonamento" nelle schede.
3. **Jellyfin (facoltativo)** — installa [Jellyfin](https://jellyfin.org/downloads/) su un PC/NAS, aggiungi le cartelle dei tuoi film e accedi da Sipario con indirizzo (es. `http://192.168.1.10:8096`), utente e password. Fuori casa serve un indirizzo raggiungibile da internet, ad esempio con Tailscale.

I classici gratuiti funzionano subito, senza configurare nulla.

## Come si compila (senza Mac)

Ogni `push` sul ramo `main` avvia GitHub Actions, che compila l'app su un Mac virtuale.
Il file `Sipario.ipa` si trova in **Releases** oppure in **Actions → ultimo run → Artifacts**.
Se la compilazione fallisce, nello stesso run c'è l'artifact `build-log`.

## Installazione su iPhone da Windows (Sideloadly)

Come per Armonia:

1. Trascina `Sipario.ipa` in Sideloadly, inserisci il tuo Apple ID e premi **Start**.
2. Sull'iPhone: Impostazioni → Generali → **VPN e gestione dispositivi** → autorizza il tuo Apple ID.

Con un Apple ID gratuito l'app scade dopo 7 giorni: basta reinstallarla (i dati restano).

## Struttura

| File | Cosa fa |
|---|---|
| `Sipario/TMDB.swift` | Catalogo, ricerca, disponibilità sui servizi, link alle app |
| `Sipario/Jellyfin.swift` | Accesso, libreria, streaming HLS, avanzamento visione |
| `Sipario/Archive.swift` | Classici di pubblico dominio dall'Internet Archive |
| `Sipario/Playback.swift` | Player a schermo intero, Picture in Picture, ripresa |
| `Sipario/MyList.swift` | La mia lista e avanzamento dei classici |
| `Sipario/Views/` | Home, schede, libreria, classici, ricerca, sorpresa, impostazioni |
| `design/AppIcon.svg` | Sorgente dell'icona |
