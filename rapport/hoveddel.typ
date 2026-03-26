= Funktionsbeskrivelse

== Systembeskrivelse
Løsningen skal være en webapplikation bygget på trelagsmodellen, som lader lærere oprette en digital vejlednings-kø, og elever kan tilmelde dem selv digitalt og løbende holde styr på deres plads i køen.

Løsningen skal bygges med PostgresSQL som datalag, en Golang HTTP API som logiklag og en React/SolidJS frontend som præsentationslag. Brugerne får serveret hele React/SolidJS applikationen ned, som er bygget til at interagere med API'et.

== Kravspecifikation
Essentielle krav:
- Systemet skal tillade lærere at logge ind på sikker vis.
- Systemet skal tillade lærere at oprette køer samt lade dem markere elever hjulpet.
- Systemet skal kunne huske elever når de er i kø, selvom de lukker deres fane.
- Systemet skal rydde op i data efterhånden som de forældes (72 timer).
- Systemet skal være tæt på realtime, så elevernes position hurtigst muligt bliver opdateret på deres enhed.

Testkrav:
- Interfacet skal være intuitivt.

= Dokumentation af programmet
== Arkitektur
Nedenfor er der et blokdiagram af, hvordan applikationens arkitektur er skruet sammen.
#align(center)[
  #image("billeder/arkitektur.png", width: 66%)
]

Vi har defineret en server som består af primært to forskellige services. En database, som i dette projekt er en Postgres-database, og en API.
API'ets opgave er dels at servere vores statiske filer, som vi bygger fra frontenden med `docker build`, men dens primære opgave er at opføre sig som vores logiklag.

Når brugeren skal have data, sender den en HTTP(S)-anmodning til vores server som ender hos vores API. API'et interagerer med Postgres SQL-databasen vha. TCP på et internt netværk, læser brugerens cookies, tjekker om session-cookien er valid og om brugeren har rettigheder til at gøre det, de forsøger.

Valideringen kan for eksempel se således ud: (pseudokode)

#pad(```go
// I en request handler
ts, ok := teacherFromRequest(db, r) // Anskaf teacher session

qid, err := uuid.Parse(r.PathValue("id")) // Anskaf ID for queue

owned, err := db.QueueOwnedBy(r.Context(), qid, ts.ID) // Query database for, om queue:teacher_session_id er lig ts.ID

if !owned {
	http.Error(w, "forbidden", http.StatusForbidden)
	return
}
```, left: 16pt)

Selvom "Auth med Cookies" ovenfor er beskrevet som en separat service, er det i virkeligheden bare et par helper-funktioner i vores API. Den svarer for eksempel til funktionen `teacherFromRequest`, som er brugt ovenfor.

=== Endpoints
API'et er struktureret efter REST-principperne. Det eksponerer følgende endpoints til lærere og elever:

- POST /auth/register - Lærer-registrering med bcrypt hashing
- POST /auth/login - Login og session-oprettelse
- GET /queues - List alle køer for den lærer der er logget ind
- POST /queues/new - Opret ny kø for den lærer der er logget ind
- GET /queues/{id} - Hent kø med alle entries. Kræver lærer session
- POST /queues/{id}/join - Elever tilmelder sig køen
- POST /queues/{id}/mark-helped - Marker elev som hjulpet. Kræver lærer session

Fra vores præsentationslag, som er vores javascript-kode, bruger vi `fetch()` funktionen til at kalde disse endpoints programmatisk.


== Database
Som beskrevet tidligere, bruger jeg i projektet Postgres som SQL-database. Den kan i princippet erstattes med en vilkårlig SQL database, da der ikke bruges Postgres-specifikke funktioner i projektet.

=== ER-diagram
Nedenfor er der en visualisering af programmets database.
#align(center)[
  #image("billeder/er-skema.png", width: 66%)
]
En vigtig detalje ved dette database skema er, at relationen fra `teacher_sessions:id` til `queues:teacher_session_id` og relationen fra `queues:id` til `queue_entries:queue_id` er defineret som `ON DELETE CASCADE`. Det betyder, at når jeg invaliderer og dermed sletter vores teacher session, slettes alle køer + alle kø-entries som har noget med den teacher session at gøre.
Ved at lave den kaskadedefinition på databasepolitikken kan jeg nemt rydde op i alt data, der har med en kø at gøre, ved bare at slette deres session i databasen.

=== Oprydning i data

Som beskrevet ovenfor kan vi rydde op i alt relevant data, ved blot at slette lærerens session.
Derfor programmerer jeg en separat routine i mit API, som hver dag leder efter lærersessioner som er ældre end tre døgn:

```go
go func() {
	for {
		now := time.Now()
		next := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, time.Local)
		time.Sleep(time.Until(next))
		if err := db.DeleteOldTeacherSessions(context.Background()); err != nil {
			log.Printf("session cleanup: %v", err)
		}
	}
}()
```

Funktionen `DeleteOldTeacherSessions` afvikler simpeltnok bare dette SQL statement: `DELETE FROM teacher_sessions WHERE created_at < NOW() - INTERVAL '72 hours'`.

== Sikkerhed
=== Session-cookies
For at sikre at kun de rigtige personer har adgang til at gøre hvad de har brug for, laver jeg et cookie-baseret session system. Når lærere logger ind, opretter jeg en session med deres bruger i et separat table kaldet `teacher_sessions`. Ved hver request, sikrer jeg at den session stadig er valid:

#align(center)[
  #image("billeder/validering-flow.png", width: 66%)
  Bilag x: valideringsflow
]

Herefter kan jeg få deres bruger fra rækken som repræsenterer sessionen i tabellen vha. den relation som er beskrevet i ER-diagrammet mellem .

Derudover skal lærernes adgangskoder også hashes. Når de opretter deres adgangskode, kører jeg en hashing algorithme, som er en irreversibel matematisk funktion over plaintext koden for at gøre den ulæsbar. Når lærere forsøger at logge ind, kører jeg samme algoritme over deres givne adgangskode og ser om de stemmer overens. Golang har et bibliotek kaldet `golang.org/x/crypto/bcrypt` som hjælper med hashingfunktioner med videre, så det er det, der bruges i applikationen.

#align(center)[
  #image("billeder/hashing-flow.png", width: 66%)
  Bilag x: flow til hashing af adgangskoder
]

=== Firewall
Når jeg deployer applikationen så den er tilgængenligt til internettet, sikrer jeg at databasen kun kan tilgås fra den server, som kører API'et. Den eneste port, som er åbnet op til internettet skal være HTTPS-porten til API'et.


== Grafiske design
Jeg har lavet et udkast til designet med skitser og wireframes, hvor jeg skitserer layoutet for både telefonbrug og lærerbrug.

#align(center)[
  #image("billeder/skitse-af-lærerside.jpg", width: 66%)
  Bilag x: Skitse af lærerside
]

Designet er lavet så det overholder gestaltlovene, mere præcist loven om nærhed og loven om lukkethed.

På den primære kø-side for lærerne er der to lukkede bokse. Den ene indeholder information om at tilmelde sig til køen som elev, og den holder en liste af elever i kø elever, der tidligere har fået hjælp i køen.
Disse informationer holder vi tæt på hinanden, samtidig med at de er visuelt separeret i to bokse med en lidt dæmpet baggrund.

#align(center)[
  #image("billeder/layout-lærer.png", width: 66%)
  Bilag x: Færdige layout af lærersiden
]

På elevsiden er der en enkelt lukket boks, som præsenterer de vigtigste informationer til eleven. Den holdes simpel med vilje.

#align(center)[
  #rotate(90deg, [
    #image("billeder/layout-elev.jpg", height: 90%)
  ], reflow:true)
  Bilag x: Færdige layout af lærersiden
]
