#import "@preview/wordometer:0.1.5": word-count, total-words
#show: word-count
#let totals


#set document(
  title: "Digitalt køsystem til lærervejledning",
  author: "Aleksander Rist",
)

#set page(
  paper: "a4",
  margin: (x: 2.5cm, y: 3cm),
  numbering: "*",
)

#set text(
  size: 10.5pt,
  lang: "da",
  font: "Times New Roman"
)

#set par(
  justify: true,
  leading: 0.65em,
)


// Heading styling
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  set text(size: 22pt, weight: "bold")
  block(
    above: 1.5em,
    below: 1em,
    text(fill: rgb("#1e40af"), it)
  )
}

#show heading.where(level: 2): it => {
  set text(size: 16pt, weight: "semibold")
  block(
    above: 1.2em,
    below: 0.8em,
    text(fill: rgb("#2563eb"), it)
  )
}

#show heading.where(level: 3): it => {
  set text(size: 13pt, weight: "medium")
  block(
    above: 1em,
    below: 0.6em,
    it.body
  )
}

// Link styling
#show link: it => {
  set text(fill: rgb("#2563eb"))
  underline(it)
}

// Code styling
#show raw.line: line => {
  if line.count > 1 [
    #box(stack(
      dir: ltr,
      box(width: 16pt)[
        #line.number
      ],
      line.body
    ))
  ] else [#line.body]
}

// =========================
// TITLE PAGE
// =========================
#align(center + horizon)[
  #block(
    width: 100%,
    inset: 2em,
    [

      #text(size: 26pt, weight: "bold", fill: rgb("#1e3a8a"))[
        Digitalt køsystem til lærervejledning
      ]

      #v(1em)

      #text(size: 14pt, fill: gray)[
        Projektstart 09/03/2026
      ]

      #text(size: 14pt, fill: gray)[
        Aflevering 27/03/2026
      ]

      #v(2em)

      #line(length: 50%, stroke: 0.5pt + gray)

      #v(2em)

      #text(size: 13pt, weight: "medium")[
        *Aleksander Rist*
      ]

      #text(size: 11pt, style: "italic")[
        H.C Ørsted Gymnasiet
      ]

      #v(1em)


      #text(size: 10pt)[
        Informatik B
      ]

      #v(2em)

      #text(size: 11pt, weight: "medium")[
        *Lærer*
      ]


      #text(size: 10pt)[
        Bo Larsen
      ]


      #v(1.5em)

      #text(size: 11pt, weight: "medium")[
        *Omfang*
      ]

      #text(size: 10pt)[
        Tegn: #totals \
        Sider: 19
      ]
    ]
  )
]

#include "resume.typ"

// =========================
// TABLE OF CONTENTS
// =========================

#pagebreak()
#align(center)[
  #text(size: 22pt, weight: "bold", fill: rgb("#1e40af"))[
    Indholdsfortegnelse
  ]
]

#v(1.5em)

#outline(
  title: none,
  indent: auto,
  depth: 2,
)

// Problemformulering
#include "pf.typ"
#include "arbejdsspørgsmål.typ"

#set heading(
  numbering: "1.1 "
)

// =========================
// MAIN CONTENT
// =========================
#pagebreak()

#set page(numbering: "1 / 1", number-align: end)
#counter(page).update(1)

#word-count(total => [
  #totals = #total.characters
  #include "hoveddel.typ"
])

// Bibliografi
// #include "biblio.typ"
#set bibliography(
  title: none
)
= Bibliografi
#bibliography("kilder.bib", style: "harvard-cite-them-right")

= Symbolliste
// #include "sections/symboler.typ"

= Bilag
// #include "bilag.typ"
