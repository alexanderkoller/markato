# Markato website

The product site is built with [Tola](https://github.com/tola-rs/tola-ssg), using Typst for the page source and plain CSS for presentation.

## Local development

The site is pinned to Tola 0.8.0. Install the checked release binary locally
for this project:

```sh
./scripts/install-tola
```

This writes to the ignored `.tola/` directory and does not replace another
Tola version installed on your system. Tola 0.8.0 is not currently published
to crates.io, so `cargo install tola --version 0.8.0` does not work.

Then start the local preview from this directory:

```sh
./scripts/tola dev
```

Tola serves the configured project-page path at <http://127.0.0.1:5277/markato/>.
Tola 0.7 used `serve`; in Tola 0.8 the command is `dev`.

Build the production site with:

```sh
./scripts/tola build --minify
```

The generated site is written to `public/` and is intentionally ignored by Git.

## Publishing

The repository workflow at `.github/workflows/pages.yml` builds this directory and deploys `website/public/` to GitHub Pages after pushes to `main`. In the repository's Pages settings, choose **GitHub Actions** as the publishing source.

The workflow passes the Pages origin and base path reported by GitHub to Tola, so asset URLs work for both project pages and custom domains.
