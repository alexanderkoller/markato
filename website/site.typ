#import "@tola/address:0.0.0": url-of-asset
#import "@tola/site:0.0.0": site
#import "@tola/web:0.0.0": head-metadata

#set text(
  lang: site.language.lang,
  script: site.language.script,
  region: site.language.region,
)

#let page-title = "Markato — fast Markdown for long documents"
#let page-description = "Markato is a clean, fast Markdown editor for Apple Silicon Macs, built to stay responsive on long documents."

#document("index.html", format: "html", title: page-title, description: page-description, author: site.authors.map(author => author.name))[
  #html.html(lang: site.language.tag)[
    #html.head[
      #for entry in head-metadata(site, title: page-title, description: page-description) { entry }
      #html.elem("meta", attrs: (name: "theme-color", content: "#f5f0e7"))
      #html.link(rel: "icon", href: url-of-asset("/assets/images/markato-icon.png"))
      #html.link(rel: "stylesheet", href: url-of-asset("/assets/css/site.css"))
    ]
    #html.body[
      #include "content/index.typ"
    ]
  ]
]

#document("404.html", format: "html", title: "Page not found")[
  #html.html(lang: site.language.tag)[
    #html.head[
      #for entry in head-metadata(site, title: "Page not found", description: "The requested Markato page could not be found.") { entry }
      #html.link(rel: "icon", href: url-of-asset("/assets/images/markato-icon.png"))
      #html.link(rel: "stylesheet", href: url-of-asset("/assets/css/site.css"))
    ]
    #html.body[
      #html.elem("main", attrs: (class: "not-found"))[
        #html.p(class: "eyebrow")[404]
        #html.elem("h1")[Page not found.]
        #html.p[There is nothing at this address.]
        #html.a(class: "button button-primary", href: site.base-path)[Return to Markato]
      ]
    ]
  ]
]
