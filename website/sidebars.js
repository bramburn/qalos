// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  // The order here controls the navbar position (left to right).
  gettingStartedSidebar: [
    'intro',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: [
        'getting-started/index',
        'getting-started/local-build',
        'getting-started/do-build',
        'getting-started/aliyun-build',
      ],
    },
  ],
  architectureSidebar: [
    {
      type: 'category',
      label: 'Architecture',
      collapsed: false,
      items: [
        'architecture/index',
        'architecture/overview',
        'architecture/safety-nets',
        'architecture/warm-image-pattern',
      ],
    },
  ],
  referenceSidebar: [
    {
      type: 'category',
      label: 'Reference',
      collapsed: false,
      items: [
        'reference/index',
        'reference/folder-structure',
        'reference/tools-reference',
        'reference/gotchas',
      ],
    },
  ],
  contributingSidebar: [
    {
      type: 'category',
      label: 'Contributing',
      collapsed: false,
      items: [
        'contributing/index',
        'contributing/how-to-contribute',
        'contributing/ci-checks',
      ],
    },
  ],
  qaLabOsSidebar: [
    {
      type: 'category',
      label: 'QA Lab OS',
      collapsed: false,
      items: [
        'qa-lab-os/index',
        'qa-lab-os/plan',
        'qa-lab-os/decisions',
        'qa-lab-os/architecture',
        'qa-lab-os/api',
        'qa-lab-os/build-guide',
        'qa-lab-os/agent-developer-guide',
        'qa-lab-os/static-checks',
        'qa-lab-os/review-log',
        'qa-lab-os/lessons-learned',
        'qa-lab-os/followup-work',
      ],
    },
  ],
};

export default sidebars;
