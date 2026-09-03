/**
 * Babel config for the Docusaurus site.
 *
 * This is required so that Docusaurus can compile React JSX, MDX, and ES modules
 * during the build. We do not need any custom plugins.
 */
module.exports = {
  presets: [
    [
      require.resolve('@docusaurus/core/lib/babel/preset'),
    ],
  ],
};
