# Fixture: rows the old loose converter turned into junk

**This list was last updated on January 1st, 2026**

| Id | Azure Local Component | Endpoint URL | Port | Notes | Arc gateway support | Required for |
|----|-----------------------|--------------|------|-------|---------------------|--------------|
| 1 | Azure Local authentication | login.microsoftonline.com | 443 | Auth. | No. Arc registration required | Deployment & Post deployment |
| 2 | Azure Local deployment | Management network | 443 | Not a host. | No | Deployment |
| 3 | Azure Local deployment | SSH | 22 | Not a host. | No | Deployment |
| 4 | Azure Local AKS infra | `pypi.org`, `*.pypi.org` | 443 | Two hosts, backticks. | No | Deployment |
| 5 | Azure Local AKS infra | Kubernetes API server | 6443 | Not a host. | No | Deployment |
| 6 | Azure Local AKS infra | https://eastus.obo.arc.azure.com | 8084 | Node-internal port. | No | Post Deployment |
| 7 | Azure Local ARB infra | time.windows.com | 123 | NTP. | No | Deployment |
| 8 | Azure Local CRLs | crl.microsoft.com/pkiinfra | 80 | CRL with path. | No | Deployment |
| 9 | Azure Local deployment | host.example.com | abc | Non numeric port. | No | Deployment |
| 10 | Azure Local deployment | multi.example.com and other.example.com | 80, 443 | Multi host and port. | Yes. 2408 or later new deployment | Deployment |
| 11 | Azure Local Arc gateway | yourarcgatewayendpointid.gw.arc.azure.com | 443 | Placeholder. | No. Arc registration required | Deployment |
| 12 | Azure Local deployment | HTTPS to private cloud control plane | 443 | Not a host. | No | Deployment |
| 13 | Azure Local deployment | bad_host!.example.com | 443 | Illegal characters. | No | Deployment |
| 14 | Azure Local monitoring | *.prod.hot.ingest.monitor.core.windows.net | 443 | Wildcard. | Yes. 2408 or later new deployment | Deployment |
| 15 | Azure Local monitoring | dc.prod.hot.ingest.monitor.core.windows.net | 443 | Concrete sibling. | Yes. 2408 or later new deployment | Deployment |
