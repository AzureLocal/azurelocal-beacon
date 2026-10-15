import { defineConfig } from 'vitepress'

const gettingStarted = [
  { text: 'Overview', link: '/getting-started/overview' },
  { text: 'Prerequisites', link: '/getting-started/prerequisites' },
  { text: 'Build the ISO', link: '/getting-started/build' },
  { text: 'Build and first-boot verification', link: '/getting-started/verify-build' },
  { text: 'Boot and Run', link: '/getting-started/boot' },
  { text: 'Walkthrough', link: '/getting-started/walkthrough' }
]

const validation = [
  { text: 'Overview', link: '/validation/index' },
  { text: 'Active Directory', link: '/validation/active-directory' },
  { text: 'Local Identity (AD-less)', link: '/validation/local-identity' },
  { text: 'Networking and Firewall', link: '/validation/network-firewall' },
  { text: 'Arc readiness', link: '/validation/arc-readiness' },
  { text: 'Category Reference', link: '/validation/category-reference' }
]

const reference = [
  { text: 'Endpoint List', link: '/reference/endpoints' },
  { text: 'Environment Checker', link: '/reference/environment-checker' },
  { text: 'Results Schema', link: '/reference/results-schema' },
  { text: 'Glossary', link: '/reference/glossary' }
]

export default defineConfig({
  // Dead links fail the docs build (CI). Do not turn this back on.
  ignoreDeadLinks: false,
  base: '/azurelocal-beacon/',
  title: 'AzL Beacon',
  description: 'Pre-deployment endpoint, network and Arc readiness validation for Azure Local',
  themeConfig: {
    logo: '/assets/images/azurelocal-beacon-icon.svg',
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Getting Started', items: gettingStarted },
      { text: 'Validation', items: validation },
      { text: 'Drivers', items: [{ text: 'Dell AX NIC Drivers', link: '/drivers/dell-ax' }] },
      { text: 'Reference', items: reference },
      { text: 'Contributing', link: '/contributing' }
    ],
    sidebar: [
      { text: 'Home', link: '/' },
      { text: 'Getting Started', items: gettingStarted, collapsed: false },
      { text: 'Validation', items: validation, collapsed: false },
      { text: 'Drivers', items: [{ text: 'Dell AX NIC Drivers', link: '/drivers/dell-ax' }], collapsed: false },
      { text: 'Reference', items: reference, collapsed: false },
      { text: 'Contributing', link: '/contributing' }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-beacon' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})
