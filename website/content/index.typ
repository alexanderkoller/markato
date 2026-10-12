#import "@tola/address:0.0.0": url-of-asset

#let asset(name) = url-of-asset("/assets/images/" + name)

#html.a(class: "skip-link", href: "./\u{23}main")[Skip to content]

#html.elem("header", attrs: (class: "site-header"))[
  #html.a(class: "wordmark", href: "./\u{23}top")[
    #html.img(src: asset("markato-icon.png"), alt: "", width: 44, height: 44)
    #html.span[Markato]
  ]
  #html.elem("nav")[
    #html.a(href: "./\u{23}editor")[Editor]
    #html.a(href: "./\u{23}performance")[Performance]
    #html.a(href: "./\u{23}why")[Why Markato]
    #html.a(href: "https://github.com/alexanderkoller/markato")[GitHub]
  ]
]

#html.elem("main", attrs: (id: "main"))[
  #html.elem("section", attrs: (class: "hero", id: "top"))[
    #html.div(class: "hero-copy")[
      #html.p(class: "eyebrow")[Markdown for Apple Silicon]
      #html.elem("h1")[Clean on the page.#html.br()Fast under pressure.]
      #html.p(class: "lede")[Markato is a native Markdown editor for Mac. Write source on the left, read the live preview on the right, and keep moving when the document gets huge.]
      #html.div(class: "hero-actions")[
        #html.a(class: "button button-primary", href: "https://github.com/alexanderkoller/markato\u{23}build-from-source")[Build Markato]
        #html.a(class: "button button-text", href: "./\u{23}editor")[See the editor #html.span[↓]]
      ]
      #html.p(class: "requirements")[Development prototype · macOS 15 or later · Apple Silicon]
    ]
    #html.div(class: "hero-mark")[
      #html.img(src: asset("markato-icon.png"), alt: "", width: 1024, height: 1024)
    ]
  ]

  #html.elem("section", attrs: (class: "editor-section", id: "editor"))[
    #html.div(class: "section-intro")[
      #html.p(class: "section-number")[01 / The editor]
      #html.div[
        #html.elem("h2", attrs: (id: "editor-title"))[Write here. Read there.]
        #html.p[The split view that made MacDown useful, with a preview built to remain quick as your file grows. The source stays plain text. The preview follows the passage you are working on.]
      ]
    ]

    #html.elem("figure", attrs: (class: "app-shot"))[
      #html.div(class: "window-bar")[
        #html.span[]
        #html.span[]
        #html.span[]
        #html.elem("b")[Example.md]
      ]
      #html.img(
        src: asset("markato-editor.png"),
        alt: "Markato showing Markdown source beside a live formatted preview with headings, prose, equations, and an image.",
        width: 2240,
        height: 1520,
      )
      #html.elem("figcaption")[Source and preview stay side by side. Drag the divider, hide the preview, or follow the document in sync.]
    ]
  ]

  #html.elem("section", attrs: (class: "feature-ledger"))[
    #html.elem("article")[
      #html.p(class: "feature-index")[A]
      #html.elem("h3")[One file at a time]
      #html.p[Open a Markdown file, edit it, save it. No workspace, account, library, or new file format.]
    ]
    #html.elem("article")[
      #html.p(class: "feature-index")[B]
      #html.elem("h3")[The useful parts]
      #html.p[Tables, code fences, images, equations, and Mermaid diagrams render in the preview.]
    ]
    #html.elem("article")[
      #html.p(class: "feature-index")[C]
      #html.elem("h3")[Works offline]
      #html.p[Fonts, styles, syntax highlighting, math, and diagram rendering are bundled with the app.]
    ]
  ]

  #html.elem("section", attrs: (class: "performance", id: "performance"))[
    #html.div(class: "performance-copy")[
      #html.p(class: "section-number light")[02 / Performance]
      #html.elem("h2", attrs: (id: "performance-title"))[An 8 MB document.#html.br()#html.elem("strong")[Open in 0.26 seconds.]]
      #html.p[On an Apple M4 Pro, Markato reached a visible preview 9.7 times faster than MacDown 2.0 and 46 times faster than MacDown 0.7.3 in the same test.]
      #html.p(class: "fine-print")[Controlled same-machine benchmark. Median of three fresh-process opens. Results describe the tested hardware and documents, not every Mac or Markdown file.]
      #html.a(class: "text-link", href: "https://github.com/alexanderkoller/markato/blob/main/docs/performance.md")[Read the benchmark and method #html.span[↗]]
    ]

    #html.elem("figure", attrs: (class: "performance-chart"))[
      #html.img(
        src: asset("markato-performance.png"),
        alt: "Bar chart showing Markato opening an 8 MB Markdown file in 0.26 seconds, MacDown 2.0 in 2.48 seconds, MacDown 0.7.3 in 11.87 seconds, and MarkViewer and MacDown 3000 timing out after 60 seconds.",
        width: 1600,
        height: 960,
      )
    ]
  ]

  #html.elem("section", attrs: (class: "lineage", id: "why"))[
    #html.div(class: "lineage-heading")[
      #html.p(class: "section-number")[03 / Why Markato]
      #html.elem("h2", attrs: (id: "lineage-title"))[MacDown showed the way.#html.br()Markato takes it forward.]
    ]
    #html.div(class: "lineage-body")[
      #html.p[MacDown got the shape right: Markdown source, a rendered preview, and very little in the way. Markato keeps that directness.]
      #html.p[But the original MacDown 0.7.3 release is an Intel app. Markato is built for Apple Silicon and current macOS, with a preview architecture designed around documents that no longer fit the old assumptions.]
      #html.p[MacDown 2.0 and MacDown 3000 are part of the same ongoing story. Markato is a separate answer: familiar where it helps, new where performance demands it.]
    ]
  ]

  #html.elem("section", attrs: (class: "plain-list"))[
    #html.div[
      #html.p(class: "section-number")[04 / In the box]
      #html.elem("h2", attrs: (id: "inside-title"))[Just the things you expect.]
    ]
    #html.elem("ul")[
      #html.elem("li")[#html.span[01] Synchronized source and preview]
      #html.elem("li")[#html.span[02] Search, undo, redo, and text sizing]
      #html.elem("li")[#html.span[03] Syntax-highlighted code blocks]
      #html.elem("li")[#html.span[04] Tables and local or web images]
      #html.elem("li")[#html.span[05] Inline and display mathematics]
      #html.elem("li")[#html.span[06] Mermaid diagrams rendered as SVG]
    ]
  ]

  #html.elem("section", attrs: (class: "closing"))[
    #html.img(src: asset("markato-icon.png"), alt: "Markato app icon", width: 160, height: 160)
    #html.div[
      #html.p(class: "eyebrow")[Early, open, and useful]
      #html.elem("h2")[Markato is a development prototype.]
      #html.p[It is ready to explore and build from source. It is not pretending to be finished.]
      #html.div(class: "hero-actions")[
        #html.a(class: "button button-primary", href: "https://github.com/alexanderkoller/markato\u{23}build-from-source")[Build from source]
        #html.a(class: "button button-text", href: "https://github.com/alexanderkoller/markato")[View on GitHub #html.span[↗]]
      ]
    ]
  ]
]

#html.elem("footer")[
  #html.p[Markato]
  #html.p[A fast Markdown editor for long documents.]
  #html.p[#html.a(href: "https://github.com/alexanderkoller/markato")[Source on GitHub]]
]
