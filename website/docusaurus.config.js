// @ts-check
// `@type` JSDoc annotations let editors provide autocompletion and type checking.
// (When running `docusaurus build` Docusaurus loads this file as ES module.)

import { themes as prismThemes } from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'qalos',
  tagline: 'QA Lab Operating System — opinionated AOSP fork for QA work',
  favicon: 'img/favicon.ico',

  // Set the production URL of your site here. DO NOT commit a real domain unless
  // you control it. For GitHub Pages the format is https://<org>.github.io.
  url: 'https://bramburn.github.io',
  // The base URL of your repo on GitHub Pages. For project pages: /<repoName>/
  baseUrl: '/qalos/',

  // GitHub Pages deployment config. Used by `npm run deploy` and the
  // deploy-docs.yml workflow. MUST match the repo's actual owner / name.
  organizationName: 'bramburn',
  projectName: 'qalos',

  // Even if you don't use internalization, you can set this to keep the
  // generated HTML small.
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  // Treat warnings as errors during production builds to fail fast on broken
  // links, missing keys, etc. Disable locally if you have false positives.
  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',

  // GitHub Pages serves from the root of the published site, but for a
  // project page (https://bramburn.github.io/qalos/) we need a trailing slash.
  trailingSlash: 'always',

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: './sidebars.js',
          // Don't show the last update time on every page - it's noisy for a
          // small project where most pages change together.
          showLastUpdateTime: false,
          // Show reading time at the bottom of each page.
          showReadingTime: true,
          editUrl:
            'https://github.com/bramburn/qalos/edit/main/website/',
          routeBasePath: '/',
        },
        blog: false,        // we don't need a blog
        pages: false,       // we use the src/pages/index.js home page instead
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      // The clean theme is the default; we keep it.
      image: 'img/social-card.png',
      colorMode: {
        defaultMode: 'light',
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: 'qalos',
        logo: {
          alt: 'qalos logo',
          src: 'img/logo.svg',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'gettingStartedSidebar',
            position: 'left',
            label: 'Get started',
          },
          {
            type: 'docSidebar',
            sidebarId: 'architectureSidebar',
            position: 'left',
            label: 'Architecture',
          },
          {
            type: 'docSidebar',
            sidebarId: 'referenceSidebar',
            position: 'left',
            label: 'Reference',
          },
          {
            type: 'docSidebar',
            sidebarId: 'contributingSidebar',
            position: 'left',
            label: 'Contributing',
          },
          {
            type: 'docSidebar',
            sidebarId: 'qaLabOsSidebar',
            position: 'left',
            label: 'QA Lab OS',
          },
          {
            href: 'https://github.com/bramburn/qalos',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              { label: 'Get started', to: '/docs/getting-started/' },
              { label: 'Architecture', to: '/docs/architecture/overview' },
              { label: 'Reference', to: '/docs/reference/folder-structure' },
            ],
          },
          {
            title: 'Project',
            items: [
              { label: 'GitHub repo', href: 'https://github.com/bramburn/qalos' },
              { label: 'Issues', href: 'https://github.com/bramburn/qalos/issues' },
              { label: 'Discussions', href: 'https://github.com/bramburn/qalos/discussions' },
            ],
          },
          {
            title: 'More',
            items: [
              { label: 'AOSP upstream', href: 'https://source.android.com/' },
              { label: 'AGENTS.md (canonical)', to: '/AGENTS' },
            ],
          },
        ],
        copyright: `qalos source is MIT. AOSP components are Apache 2.0. Copyright © ${new Date().getFullYear()} the qalos contributors.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'powershell', 'json', 'xml', 'diff'],
      },
      algolia: undefined,  // we don't have algolia configured
    }),

  // Trailing-slash normalization for GitHub Pages: served as static files
  // from the build output, so we need a clean-url config.
  staticDirectories: ['static'],

  // Useful build flags
  future: {
    experimental_faster: true,
  },
};

export default config;
