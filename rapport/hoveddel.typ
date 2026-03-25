= Dokumentation af udvikling

== Systembeskrivelse
Løsningen er en webapplikation bygget på trelagsmodellen, som lader lærere oprette en digital vejlednings-kø, og elever kan tilmelde dem selv digitalt, holde styr på deres plads og lave en note.

== Arkitektur
Nedenfor er der et blokdiagram af, hvordan applikationens arkitektur er skruet sammen.
#align(center)[
  #image("billeder/arkitektur.png", width: 66%)
]

Vi har defineret en server som består af primært to forskellige services. En database, som i dette projekt er en Postgres-database, og en API.
API'ets opgave er dels at servere vores statiske filer, som vi bygger fra frontenden med `Docker build`, men dens primære opgave er at opføre sig som vores logiklag.

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
- GET /queues/{id} - Hent kø med entries
- POST /queues/{id}/join - Elever tilmelder sig kø
- POST /queues/{id}/mark-helped - Marker elev som hjulpet


== Sikkerhed
For at sikre at kun de rigtige personer har adgang til at gøre hvad de har brug for, laver jeg et cookie-baseret session system. Når lærere logger ind, opretter jeg en session med deres bruger i et separat table. Ved hver request, sikrer jeg at den session stadig er valid, og jeg kan også få deres bruger.

Derudover skal lærernes adgangskoder også hashes. Når de opretter deres adgangskode, kører jeg en hashing algorithme, som er en irreversibel matematisk funktion over plaintext koden for at gøre den ulæsbar. Når lærere forsøger at logge ind, kører jeg samme algoritme over deres givne adgangskode og ser om de stemmer overens. Golang har et bibliotek kaldet `golang.org/x/crypto/bcrypt` som hjælper med hashingfunktioner med videre, så det er det, der bruges i applikationen.

#align(center)[
  #image("billeder/hashing-flow.png", width: 66%)
]


== Database
Som beskrevet tidligere, bruger jeg i projektet Postgres som SQL-database. Den kan i princippet erstattes med en vilkårlig SQL database, da der ikke bruges Postgres-specifikke funktioner i projektet.

=== ER-diagram
Nedenfor er der en visualisering af programmets database.
#align(center)[
  #image("billeder/er-skema.png", width: 66%)
]
En vigtig detalje ved dette database skema er, at relationen fra `teacher_sessions:id` til `queues:teacher_session_id` og relationen fra `queues:id` til `queue_entries:queue_id` er defineret som `ON DELETE CASCADE`. Det betyder, at når jeg invaliderer og dermed sletter vores teacher session, slettes alle køer + alle kø-entries som har noget med den teacher session at gøre.
Ved at lave den kaskadedefinition på databasepolitikken kan jeg nemt rydde op i alt data, der har med en kø at gøre, ved bare at slette deres session i databasen.




== Grafiske design
Gestaltlovene

== Tests
