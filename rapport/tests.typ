= Test af programmet

Programmet er blevet testet gennem en brugertest.
Tre testelever og en testlærer brugte platformen til at få og give feedback, hvor eleverne scannede QR-koden, skrev navn og note på og læreren markerede elever som hjulpet.
Generelt var deres feedback god. Systemet var hurtigt og intuitivt, og der var ikke nogen af eleverne der havde bøvl ved at tilmelde sig, eller synes at de savnede information.

En af eleverne meldte tilbage, at de savnede en måde hvorpå de kunne fjerne sig selv fra køen. Overordnet har produktet dog fået meget ros, og testeleverne kan sagtens se værdien i, at gå væk fra en analog tavleliste.

== Demo

Her er en QR-kode til en video, som fremviser produktets primære funktioner med to testpersoner.
#import "@preview/cades:0.3.1": qr-code
#align(center)[
  #qr-code("https://drive.google.com/file/d/1rp3r1qcM1VpInKTQpwRgIVWLG09-CA9L/view?usp=drive_link", width: 33%)
]
https://drive.google.com/file/d/1rp3r1qcM1VpInKTQpwRgIVWLG09-CA9L/view?usp=drive_link

Projektet kan køres med Docker vha. `docker compose up` og kan derefter tilgås på http://localhost:8080/register for at registrere en ny lærerbruger.

Hvis man ikke vil det, kan man tilgå appen på https://inf-eksamensprojekt-production.up.railway.app/queues så længe den forbliver oppe. En konto eksisterer allerede med navn `test` og kode `testkode`.
