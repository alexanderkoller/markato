#import "@tola/address:0.0.0": url-of-asset

#let asset(name) = url-of-asset("/assets/images/" + name)
#let download-url = "https://github.com/alexanderkoller/markato/releases/latest"

#html.a(class: "skip-link", href: "./\u{23}main")[Skip to content]

#html.elem("header", attrs: (class: "site-header"))[
  #html.a(class: "wordmark", href: "./\u{23}top")[
    #html.img(src: asset("markato-icon.png"), alt: "", width: 42, height: 42)
    #html.span[Markato]
  ]
  #html.elem("nav")[
    #html.a(href: "./\u{23}advances")[What’s new]
    #html.a(href: "./\u{23}performance")[Performance]
    #html.a(href: "./\u{23}lineage")[MacDown]
    #html.a(class: "nav-download", href: download-url)[Download]
  ]
]

#html.elem("main", attrs: (id: "main"))[
  #html.elem("section", attrs: (class: "hero", id: "top"))[
    #html.div(class: "hero-copy")[
      #html.p(class: "eyebrow")[A native Markdown editor for Apple Silicon]
      #html.elem("h1")[Fast editing for long Markdown documents.]
      #html.p(class: "lede")[Markato follows MacDown’s source-on-the-left, preview-on-the-right design. It is built for current Macs and remains usable as a document grows.]
      #html.div(class: "hero-actions")[
        #html.a(class: "button button-primary", href: download-url)[Download for Mac]
        #html.a(class: "button button-secondary", href: "https://github.com/alexanderkoller/markato")[View source #html.span[↗]]
      ]
      #html.p(class: "requirements")[macOS 15 or later · Apple Silicon]
    ]
    #html.div(class: "hero-art")[
      #html.div(class: "hero-swatch")[]
      #html.img(src: asset("markato-icon.png"), alt: "Markato app icon", width: 1024, height: 1024)
    ]
  ]

  #html.elem("section", attrs: (class: "product", id: "editor"))[
    #html.div(class: "section-heading")[
      #html.p(class: "section-label")[Editor]
      #html.elem("h2")[Source, preview, and document outline]
      #html.p[The source editor and preview remain side by side, as in MacDown. The outline provides direct navigation through headings in longer files.]
    ]
    #html.elem("figure", attrs: (class: "app-shot"))[
      #html.img(
        src: asset("markato-window.png"),
        alt: "The complete Markato window showing its outline, Markdown source, and live preview.",
        width: 2800,
        height: 1960,
      )
      #html.elem("figcaption")[The complete Markato window: outline, source, and preview.]
    ]
  ]

  #html.elem("section", attrs: (class: "advances", id: "advances"))[
    #html.div(class: "section-heading compact")[
      #html.p(class: "section-label")[Long documents]
      #html.elem("h2")[Performance on long documents]
      #html.p[This is Markato’s principal difference from the editors that established its interface.]
    ]
    #html.div(class: "feature-grid")[
      #html.elem("article")[
        #html.div(class: "feature-icon coral")[#html.img(src: asset("icon-speed.svg"), alt: "", width: 48, height: 48)]
        #html.elem("h3")[Fast opening]
        #html.p[The editor reaches a usable preview without waiting for every part of a long document to finish rendering.]
      ]
      #html.elem("article")[
        #html.div(class: "feature-icon violet")[#html.img(src: asset("icon-window.svg"), alt: "", width: 48, height: 48)]
        #html.elem("h3")[Focused preview]
        #html.p[The preview becomes usable before every part of the document has been rendered.]
      ]
      #html.elem("article")[
        #html.div(class: "feature-icon blue")[#html.img(src: asset("icon-outline.svg"), alt: "", width: 48, height: 48)]
        #html.elem("h3")[Document outline]
        #html.p[Headings form a navigable outline for moving directly between sections.]
      ]
    ]
  ]

  #html.elem("section", attrs: (class: "performance", id: "performance"))[
    #html.div(class: "performance-copy")[
      #html.p(class: "section-label")[Benchmark]
      #html.elem("p", attrs: (class: "big-number"))[0.26 #html.elem("span")[seconds]]
      #html.elem("h2")[Time to first visible preview for an 8 MB document]
      #html.p[In the same Apple M4 Pro test, that was 9.7× faster than MacDown 2.0 and 46× faster than MacDown 0.7.3.]
      #html.p(class: "fine-print")[Median of three fresh-process opens on the tested machine and document. Results are measurements, not a promise about every file or Mac.]
      #html.a(class: "text-link", href: "https://github.com/alexanderkoller/markato/blob/main/docs/performance.md")[Benchmark and method #html.span[↗]]
    ]
    #html.elem("figure", attrs: (class: "performance-chart"))[
      #html.img(
        src: asset("markato-performance.png"),
        alt: "Benchmark chart showing Markato opening an 8 MB Markdown file in 0.26 seconds.",
        width: 1600,
        height: 960,
      )
    ]
  ]

  #html.elem("section", attrs: (class: "lineage", id: "lineage"))[
    #html.div(class: "lineage-title")[
      #html.p(class: "section-label")[MacDown heritage]
      #html.elem("h2")[Markato follows MacDown’s split-pane design.]
    ]
    #html.div(class: "lineage-body")[
      #html.p(class: "lineage-lede")[MacDown established the interaction that Markato retains: Markdown source on the left, a rendered preview on the right, and ordinary Markdown files underneath.]
      #html.p[The last original MacDown release, version 0.7.3, is an Intel application. Markato targets Apple Silicon and current macOS, and its preview is designed for substantially larger documents.]
      #html.p[Markato is not the only continuation of this design. MacDown 2.0 and MacDown 3000 pursue related goals in their own implementations.]
      #html.div(class: "lineage-links")[
        #html.a(href: "https://github.com/MacDownApp/macdown")[Original MacDown #html.span[↗]]
        #html.a(href: "https://github.com/xuanji86/MacDown2.0")[MacDown 2.0 #html.span[↗]]
        #html.a(href: "https://macdown.app/")[MacDown 3000 #html.span[↗]]
      ]
    ]
  ]

  #html.elem("section", attrs: (class: "essentials"))[
    #html.div(class: "section-heading compact")[
      #html.p(class: "section-label")[Markdown support]
      #html.elem("h2")[Features available in the preview]
    ]
    #html.elem("ul")[
      #html.elem("li")[#html.span[Math] Inline, display, aligned equations, and matrices]
      #html.elem("li")[#html.span[Code] Syntax highlighting for extended language grammars]
      #html.elem("li")[#html.span[Diagrams] Mermaid rendered locally as SVG]
      #html.elem("li")[#html.span[Files] Local and web images, tables, search, undo, and save]
      #html.elem("li")[#html.span[Offline] Fonts, styles, math, and diagram rendering are bundled]
      #html.elem("li")[#html.span[Focus] Adjustable panes and a preview you can hide]
    ]
  ]

  #html.elem("section", attrs: (class: "download", id: "download"))[
    #html.img(src: asset("markato-icon.png"), alt: "", width: 112, height: 112)
    #html.div[
      #html.p(class: "section-label")[Markato for Mac]
      #html.elem("h2")[Download Markato]
      #html.p[Markato requires macOS 15 or later on an Apple Silicon Mac. It uses ordinary Markdown files and requires no account.]
    ]
    #html.a(class: "button button-download", href: download-url)[Download for Mac]
  ]
]

#html.elem("footer")[
  #html.p[© 2026 Markato]
  #html.p[A Markdown editor for long documents.]
  #html.p[#html.a(href: "https://github.com/alexanderkoller/markato")[GitHub #html.span[↗]]]
]
