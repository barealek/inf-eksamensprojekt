= Arbejdsspørgsmål
For at guide hen imod, hvordan applikationen teknisk skal implementeres, er der opstillet nogle spørgsmål som der besvares

=== Hvordan kan man implementere realtidskommunikation, så køen opdateres omgående på elevernes enheder?
For at få realtidskommunikation kan man bruge en protokol kaldet Websockets. Websockets muliggør det at åbne en kanal som tillader tovejs-kommunikation, ligesom TCP. @mdn:websockets

Websockets er dog et stort besvær at implementere. Alle kanaler skal ryddes op, og der skal køre en separat rutine køre på serveren for hver websocket kanal. Derfor er det som regel nemmere at lave et polling-baseret system, hvor klienterne i et givent interval henter nye informationer ned, bare ved et normalt API-kald.

Polling giver ikke mulighed for at få ægte realtidskommunikation, og det er som regel dyrere i processorkraft. Men simpliciteten gør det nemmere at implementere i dette projekt.

=== Hvordan kan man sikre, at kun den lærer, der opretter en vejledningskø, har adgang til at administrere den?
For at sikre at kun de rigtige personer har adgang til at administrere, laver vi et cookie-baseret session system. Når lærere logger ind, opretter vi en session med deres bruger i et separat table. Ved hver request, sikrer vi at den session stadig er valid, og vi kan også få deres bruger.

=== Hvordan holder man styr på elevernes session uden at kræve login?
Dette løses også igennem cookies. Når elever skriver deres navn og tilføjer dem selv til en kø, oprettes en secret som sættes i en cookie. Den secret kan vi tjekke om er rigtig i hver af de følgende requests, og vi behøver ikke at opbevare mere information end deres navn.

=== Hvordan kan man håndtere og rydde op i data, så gamle køer, navne mv. slettes automatisk efter en vis periode?
Man kunne holde styr på, hvornår alle køer og deres navne blev oprettet, hvornår køen stoppede mv., og derefter køre et job hver dag, som læser alle køer igennem og sletter dem, som eksempelvis er ældre end 14 dage.

For at gøre alt data så ephemeral som muligt, vælger jeg i stedet for at binde køerne i databasen til en lærer session, i stedet for en lærer selv. Dvs., når de logger ud eller deres session invalideres, kan man ikke længere tilgå de køer med videre, som læreren havde oprettet, da det er gemt på sessionen.
