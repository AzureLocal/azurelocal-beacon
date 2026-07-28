import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-beacon/',
  title: "AzL Beacon",
  description: "Governed centrally by HCS Platform Engineering standards",
  themeConfig: {
    logo: '/assets/images/azurelocal-beacon-icon.svg',
    nav: [{"link":"/","text":"Home"},{"items":[{"link":"/getting-started/overview","text":"Overview"},{"link":"/getting-started/prerequisites","text":"Prerequisites"},{"link":"/getting-started/build","text":"Build the ISO"},{"link":"/getting-started/boot","text":"Boot and Run"}],"text":"Getting Started"},{"items":[{"link":"/validation/index","text":"Overview"},{"link":"/validation/active-directory","text":"Active Directory"},{"link":"/validation/local-identity","text":"Local Identity (AD-less)"},{"link":"/validation/network-firewall","text":"Networking and Firewall"},{"link":"/validation/category-reference","text":"Category Reference"}],"text":"Validation"},{"items":{"link":"/drivers/dell-ax","text":"Dell AX NIC Drivers"},"text":"Drivers"},{"items":[{"link":"/reference/endpoints","text":"Endpoint List"},{"link":"/reference/environment-checker","text":"Environment Checker"},{"link":"/reference/results-schema","text":"Results Schema"},{"link":"/reference/glossary","text":"Glossary"}],"text":"Reference"},{"link":"/contributing","text":"Contributing"}],
    sidebar: [{"link":"/","text":"Home"},{"text":"Getting Started","items":[{"link":"/getting-started/overview","text":"Overview"},{"link":"/getting-started/prerequisites","text":"Prerequisites"},{"link":"/getting-started/build","text":"Build the ISO"},{"link":"/getting-started/boot","text":"Boot and Run"}],"collapsed":false},{"text":"Validation","items":[{"link":"/validation/index","text":"Overview"},{"link":"/validation/active-directory","text":"Active Directory"},{"link":"/validation/local-identity","text":"Local Identity (AD-less)"},{"link":"/validation/network-firewall","text":"Networking and Firewall"},{"link":"/validation/category-reference","text":"Category Reference"}],"collapsed":false},{"text":"Drivers","items":{"link":"/drivers/dell-ax","text":"Dell AX NIC Drivers"},"collapsed":false},{"text":"Reference","items":[{"link":"/reference/endpoints","text":"Endpoint List"},{"link":"/reference/environment-checker","text":"Environment Checker"},{"link":"/reference/results-schema","text":"Results Schema"},{"link":"/reference/glossary","text":"Glossary"}],"collapsed":false},{"link":"/contributing","text":"Contributing"}],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-beacon' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})




