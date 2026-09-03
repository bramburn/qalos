# qalos docs site (Docusaurus)

This directory holds the Docusaurus site that powers https://bramburn.github.io/qalos/.

The **canonical source of truth** for the architecture and design rules is [`/AGENTS.md`](../AGENTS.md) in the repo root. This site is a navigable, prettier mirror for humans browsing on the web. If the two ever disagree, `AGENTS.md` wins.

## Local preview

```bash
cd website
npm install
npm run start
```

The site is at http://localhost:3000. The first `npm install` takes 1-2 minutes.

## Build static HTML (for GitHub Pages)

```bash
cd website
npm run build
```

Output lands in `website/build/`. GitHub Pages serves the contents of `build/` from the `gh-pages` branch (managed automatically by the `deploy-docs.yml` workflow).

## Layout

```
website/
├── package.json
├── docusaurus.config.js
├── sidebars.js
├── babel.config.js
├── docs/                  # the content
│   ├── intro.md
│   ├── getting-started/
│   ├── architecture/
│   ├── reference/
│   └── contributing/
├── src/
│   ├── pages/index.js     # the home page
│   └── css/custom.css
└── static/
    ├── .nojekyll
    └── img/
```

## Adding a new page

1. Create a new `.md` file in the appropriate `docs/<section>/` directory.
2. Add the page to `sidebars.js` under the right sidebar.
3. (Optional) Add a `_category_.json` for a new section.
4. Run `npm run start` to preview locally.
5. Push to a branch. The CI workflow will lint the markdown. The `deploy-docs.yml` workflow will deploy the rebuilt site to GitHub Pages on merge to `main`.

## Editing a page

Each page has an **Edit this page** link at the bottom (configured via `editUrl` in `docusaurus.config.js`). It opens the file on GitHub in edit mode.

## Deployment

The site is auto-deployed to GitHub Pages on every push to `main` by the workflow at [`.github/workflows/deploy-docs.yml`](../.github/workflows/deploy-docs.yml). It builds the site, uploads the `build/` directory to the `gh-pages` branch, and GitHub Pages serves it.

To set up GitHub Pages for the first time:
1. Go to the repo's **Settings > Pages** on GitHub.
2. Under **Source**, select **Deploy from a branch** and choose the `gh-pages` branch / root.
3. Save. The next `deploy-docs.yml` run will populate `gh-pages` and the site will be live at `https://<org>.github.io/<repo>/`.

## What's next

- Want to add a doc page? → see the [Docusaurus docs](https://docusaurus.io/docs)
- Want to know the design rules these docs follow? → [Architecture overview](docs/architecture/overview)
