# Azure Arc required firewall endpoints

Complete outbound allowlist for all Azure Arc services in this POC. Open every endpoint in this document at the FortiGate — East US region.

**Last updated: June 5, 2026** — Sourced from live Microsoft Learn docs (azloc-2605).

> **HTTPS/TLS inspection must be disabled** on all endpoints in this document. Azure Local and Arc do not support SSL interception on any Arc-related traffic.

---

## 1. Arc-enabled servers (Connected Machine agent)

**Source:** https://learn.microsoft.com/azure/azure-arc/servers/network-requirements

| # | Endpoint | Port | Protocol | Purpose | When |
|---|---|---|---|---|---|
| 1 | `download.microsoft.com` | 443 | HTTPS | Windows install package + auto-updates | Deploy + ongoing |
| 2 | `packages.microsoft.com` | 443 | HTTPS | Linux install package + auto-updates | Deploy + ongoing |
| 3 | `login.microsoftonline.com` | 443 | HTTPS | Microsoft Entra ID authentication | Always |
| 4 | `*.login.microsoft.com` | 443 | HTTPS | Microsoft Entra ID authentication | Always |
| 5 | `pas.windows.net` | 443 | HTTPS | Microsoft Entra ID | Always |
| 6 | `management.azure.com` | 443 | HTTPS | ARM — register and manage Arc server resource | Always |
| 7 | `gbl.his.arc.azure.com` | 443 | HTTPS | Global hybrid identity services + metadata | Always |
| 8 | `eus.his.arc.azure.com` | 443 | HTTPS | East US hybrid identity services + metadata | Always |
| 9 | `*.his.arc.azure.com` | 443 | HTTPS | Hybrid identity services (all regions) | Always |
| 10 | `*.guestconfiguration.azure.com` | 443 | HTTPS | Extension management + guest configuration | Always |
| 11 | `eastus-gas.guestconfiguration.azure.com` | 443 | HTTPS | Extension management — East US | Always |
| 12 | `agentserviceapi.guestconfiguration.azure.com` | 443 | HTTPS | Notification service for extension + connectivity | Always |
| 13 | `guestnotificationservice.azure.com` | 443 | HTTPS | Notifications for extensions and connectivity | Always |
| 14 | `*.guestnotificationservice.azure.com` | 443 | HTTPS | Notifications for extensions and connectivity | Always |
| 15 | `*.servicebus.windows.net` | 443 | HTTPS | Notifications, SSH, and WAC scenarios | Always |
| 16 | `azgn*.servicebus.windows.net` | 443 | HTTPS | Notifications (alternative to row 15) | Always |
| 17 | `*.waconazure.com` | 443 | HTTPS | Windows Admin Center connectivity | If using WAC |
| 18 | `dc.services.visualstudio.com` | 443 | HTTPS | Agent telemetry | Ongoing |
| 19 | `dls.microsoft.com` | 443 | HTTPS | License validation (hotpatch / PAYG billing) | If using WS benefits |
| 20 | `www.microsoft.com/pkiops/certs` | 80, 443 | HTTP/HTTPS | Intermediate cert updates for ESU | If using ESU |
| 21 | `graph.microsoft.com` | 443 | HTTPS | Graph authentication and RBAC | Always |
| 22 | `graph.windows.net` | 443 | HTTPS | Graph authentication | Always |

---

## 2. Arc-enabled Kubernetes

**Source:** https://learn.microsoft.com/azure/azure-arc/kubernetes/network-requirements

> `*.servicebus.windows.net` requires **WebSocket (wss) outbound** — verify the FortiGate policy allows wss on port 443.

| # | Endpoint | Port | Protocol | Purpose | When |
|---|---|---|---|---|---|
| 1 | `management.azure.com` | 443 | HTTPS | Register cluster + ARM operations | Always |
| 2 | `eastus.dp.kubernetesconfiguration.azure.com` | 443 | HTTPS | Agent status push + config fetch (East US) | Always |
| 3 | `login.microsoftonline.com` | 443 | HTTPS | Fetch and update ARM tokens | Always |
| 4 | `eastus.login.microsoft.com` | 443 | HTTPS | Fetch and update ARM tokens | Always |
| 5 | `login.windows.net` | 443 | HTTPS | Fetch and update ARM tokens | Always |
| 6 | `mcr.microsoft.com` | 443 | HTTPS | Pull Arc agent container images | Deploy + updates |
| 7 | `*.data.mcr.microsoft.com` | 443 | HTTPS | Pull Arc agent container images | Deploy + updates |
| 8 | `dl.k8s.io` | 443 | HTTPS | Download kubectl binaries during onboarding | Onboarding only |
| 9 | `gbl.his.arc.azure.com` | 443 | HTTPS | Get regional endpoint for MI certs | Always |
| 10 | `eus.his.arc.azure.com` | 443 | HTTPS | East US MI certs | Always |
| 11 | `*.his.arc.azure.com` | 443 | HTTPS | Pull system-assigned Managed Identity certs | Always |
| 12 | `guestnotificationservice.azure.com` | 443 | HTTPS | Cluster Connect + Custom Location | Always |
| 13 | `*.guestnotificationservice.azure.com` | 443 | HTTPS | Cluster Connect + Custom Location | Always |
| 14 | `sts.windows.net` | 443 | HTTPS | Cluster Connect + Custom Location | Always |
| 15 | `*.servicebus.windows.net` | 443 | WSS | Cluster Connect + Custom Location | Always |
| 16 | `graph.microsoft.com` | 443 | HTTPS | Azure RBAC | Always |
| 17 | `*.arc.azure.net` | 443 | HTTPS | Manage clusters in Azure portal | Ongoing |
| 18 | `eastus.obo.arc.azure.com` | **8084** | HTTPS | Cluster Connect + Azure RBAC | Always |
| 19 | `linuxgeneva-microsoft.azurecr.io` | 443 | HTTPS | Arc-enabled Kubernetes extension images | Always |
| 20 | `raw.githubusercontent.com` | 443 | HTTPS | GitHub (not required on 2504+) | Deploy |

---

## 3. AKS Arc (AKS on Azure Local)

**Source:** https://learn.microsoft.com/azure/aks/aksarc/network-system-requirements

> Internet-bound URLs for AKS Arc on Azure Local 2504+ are consolidated into `azurelocal-endpoints.md`. The endpoints below supplement that list.

| # | Endpoint | Port | Protocol | Purpose | When |
|---|---|---|---|---|---|
| 1 | `msk8s.api.cdp.microsoft.com` | 443 | HTTPS | Download AKS catalog, bits, and OS images from SFS | Deploy + updates |
| 2 | `msk8s.b.tlu.dl.delivery.mp.microsoft.com` | 80 | HTTP | SFS catalog and image download | Deploy + updates |
| 3 | `msk8s.f.tlu.dl.delivery.mp.microsoft.com` | 80 | HTTP | SFS catalog and image download | Deploy + updates |
| 4 | `msk8s.sb.tlu.dl.delivery.mp.microsoft.com` | 443 | HTTPS | Download Arc Resource Bridge OS images | Deploy + updates |
| 5 | `ecpacr.azurecr.io` | 443 | HTTPS | Pull container images | Deploy + updates |
| 6 | `mcr.microsoft.com` | 443 | HTTPS | Pull container images | Deploy + updates |
| 7 | `*.mcr.microsoft.com` | 443 | HTTPS | Pull container images | Deploy + updates |
| 8 | `*.data.mcr.microsoft.com` | 443 | HTTPS | Pull container images | Deploy + updates |
| 9 | `*.blob.core.windows.net` | 443 | HTTPS | Pull container images + storage | Always |
| 10 | `eastus.dp.kubernetesconfiguration.azure.com` | 443 | HTTPS | Onboard AKS clusters to Arc | Deploy |
| 11 | `gbl.his.arc.azure.com` | 443 | HTTPS | Regional endpoint for MI certs | Always |
| 12 | `*.his.arc.azure.com` | 443 | HTTPS | Pull MI certs | Always |
| 13 | `k8connecthelm.azureedge.net` | 443 | HTTPS | Helm 3 client download for Arc agents | Deploy |
| 14 | `k8connecthelm.download.prss.microsoft.com` | 443 | HTTPS | Helm client download (alternate) | Deploy |
| 15 | `*.arc.azure.net` | 443 | HTTPS | Manage AKS Arc clusters in portal | Ongoing |
| 16 | `dl.k8s.io` | 443 | HTTPS | Download Kubernetes binaries | Deploy + updates |
| 17 | `akshci.azurefd.net` | 443 | HTTPS | AKS billing | Deploy |
| 18 | `v20.events.data.microsoft.com` | 443 | HTTPS | Diagnostic data from host | Ongoing |
| 19 | `gcs.prod.monitoring.core.windows.net` | 443 | HTTPS | Diagnostic data from host | Ongoing |
| 20 | `hybridaks.azurecr.io` | 443 | HTTPS | AKS Arc container images | Deploy + updates |
| 21 | `aszk8snetworking.azurecr.io` | 443 | HTTPS | AKS Arc networking images | Deploy + updates |

---

## 4. Arc Resource Bridge (ARB)

**Source:** https://learn.microsoft.com/azure/azure-arc/resource-bridge/network-requirements

All outbound TCP 443 unless noted. Applies to appliance VM IPs, control plane IP, and management machine.

| # | Endpoint | Port | Protocol | Purpose | Applies to |
|---|---|---|---|---|---|
| 1 | `login.microsoftonline.com` | 443 | HTTPS | Update ARM tokens | Both |
| 2 | `*.login.microsoft.com` | 443 | HTTPS | Update ARM tokens | Both |
| 3 | `login.windows.net` | 443 | HTTPS | Update ARM tokens | Both |
| 4 | `management.azure.com` | 443 | HTTPS | ARM control plane | Both |
| 5 | `graph.microsoft.com` | 443 | HTTPS | Azure RBAC | Both |
| 6 | `eastus.dp.prod.appliances.azure.com` | 443 | HTTPS | ARB dataplane — communicate with RP in Azure | Appliance VM |
| 7 | `*.blob.core.windows.net` | 443 | HTTPS | Pull container images + CLI install | Both |
| 8 | `ecpacr.azurecr.io` | 443 | HTTPS | Pull container images | Appliance VM |
| 9 | `gbl.his.arc.azure.com` | 443 | HTTPS | Pull system-assigned MI certs | Appliance VM |
| 10 | `eus.his.arc.azure.com` | 443 | HTTPS | Pull system-assigned MI certs — East US | Appliance VM |
| 11 | `*.his.arc.azure.com` | 443 | HTTPS | Pull system-assigned MI certs | Appliance VM |
| 12 | `azurearcfork8s.azurecr.io` | 443 | HTTPS | Pull Arc for K8s container images | Appliance VM |
| 13 | `azurearcfork8sdev.azurecr.io` | 443 | HTTPS | Pull Arc for K8s dev images | Appliance VM |
| 14 | `kvamanagementoperator.azurecr.io` | 443 | HTTPS | Pull artifacts for appliance components | Appliance VM |
| 15 | `linuxgeneva-microsoft.azurecr.io` | 443 | HTTPS | Push logs for appliance components | Appliance VM |
| 16 | `packages.microsoft.com` | 443 | HTTPS | Linux install package | Appliance VM |
| 17 | `sts.windows.net` | 443 | HTTPS | Custom Location | Appliance VM |
| 18 | `guestnotificationservice.azure.com` | 443 | HTTPS | Azure Arc connectivity | Appliance VM |
| 19 | `*.servicebus.windows.net` | 443 | WSS | Secure control channel | Appliance VM |
| 20 | `*.arc.azure.net` | 443 | HTTPS | Manage cluster from Azure portal | Appliance VM |
| 21 | `gcs.prod.monitoring.core.windows.net` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 22 | `*.prod.microsoftmetrics.com` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 23 | `*.prod.hot.ingest.monitor.core.windows.net` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 24 | `*.prod.warm.ingest.monitor.core.windows.net` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 25 | `adhs.events.data.microsoft.com` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 26 | `v20.events.data.microsoft.com` | 443 | HTTPS | Diagnostic data | Appliance VM |
| 27 | `*.dp.kubernetesconfiguration.azure.com` | 443 | HTTPS | Dataplane for Arc agent | Mgmt machine |
| 28 | `*.web.core.windows.net` | 443 | HTTPS | Download ARB extension | Mgmt machine |
| 29 | `pypi.org`, `*.pypi.org` | 443 | HTTPS | Validate K8s + Python versions | Mgmt machine |
| 30 | `pythonhosted.org`, `*.pythonhosted.org` | 443 | HTTPS | Python packages for CLI install | Mgmt machine |

---

## 5. Azure Monitor Agent (AMA)

**Source:** https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration

All outbound TCP 443. These endpoints are **ongoing** — polled continuously at runtime, not just at deploy time.

### AMA on Arc-enabled servers

| # | Endpoint | Port | Purpose |
|---|---|---|---|
| 1 | `global.handler.control.monitor.azure.com` | 443 | Access the control service |
| 2 | `eastus.handler.control.monitor.azure.com` | 443 | Fetch DCRs for East US machines |
| 3 | `global.prod.microsoftmetrics.com` | 443 | Metrics service |
| 4 | `<log-analytics-workspace-id>.ods.opinsights.azure.com` | 443 | Ingest log data |
| 5 | `management.azure.com` | 443 | Custom metrics (time series) |
| 6 | `eastus.monitoring.azure.com` | 443 | Custom metrics — East US |
| 7 | `<data-collection-endpoint>.eastus.ingest.monitor.azure.com` | 443 | Log data ingestion via DCE |

### AMA on Kubernetes — Container Insights + Managed Prometheus

**Source:** https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-firewall

| # | Endpoint | Port | Purpose |
|---|---|---|---|
| 1 | `global.handler.control.monitor.azure.com` | 443 | Access the control service |
| 2 | `eastus.handler.control.monitor.azure.com` | 443 | Fetch DCRs for East US clusters |
| 3 | `*.ods.opinsights.azure.com` | 443 | Log ingestion |
| 4 | `*.oms.opinsights.azure.com` | 443 | OMS ingestion |
| 5 | `*.monitoring.azure.com` | 443 | Metrics |
| 6 | `*.ingest.monitor.azure.com` | 443 | Container Insights log ingestion |
| 7 | `*.metrics.ingest.monitor.azure.com` | 443 | Managed Prometheus metrics ingestion |
| 8 | `login.microsoftonline.com` | 443 | Authentication |
| 9 | `dc.services.visualstudio.com` | 443 | Telemetry |

---

## 6. Non-internet ports (internal / cross-VLAN)

These are not internet endpoints. They must be permitted in the OOB management network and cluster network ACLs — **not** in the FortiGate internet policy.

### ARB appliance VM ↔ management machine (bidirectional)

| Port | Purpose |
|---|---|
| 22 | SSH |
| 443 | HTTPS to private cloud control plane |
| 6443 | Kubernetes API server |
| 2379, 2380 | etcd (cluster upgrade) |
| 10250, 10257, 10259 | Kubernetes node and controller manager |

### AKS Arc — internal cluster ports

| Port | Source | Destination | Purpose |
|---|---|---|---|
| 22 | Management network | AKS Arc VM logical network | Log collection |
| 6443 | Management network | AKS Arc VM logical network | Kubernetes API |
| 55000 | AKS Arc VM logical network | Cluster IP | Cloud Agent gRPC server |
| 65000 | AKS Arc VM logical network | Cluster IP | Cloud Agent gRPC authentication |

### Azure Local MOC — ARB on Azure Local

| Port | Purpose |
|---|---|
| 55000 | MOC cloud agent — appliance VM + control plane to cloud agent endpoint |
| 65000 | MOC cloud agent — authentication |

---

## 7. Service tags

Allow these Azure service tags at the FortiGate in addition to the FQDNs above.

| Service tag | Used by |
|---|---|
| `AzureActiveDirectory` | All Arc services |
| `AzureResourceManager` | All Arc services |
| `AzureArcInfrastructure` | Arc-enabled servers |
| `AzureTrafficManager` | Arc-enabled servers |
| `Storage` | Arc-enabled servers, ARB |
| `AzureFrontDoor.Frontend` | Arc-enabled servers (**added April 2026**) |
| `AzureMonitor` | Azure Monitor Agent |
| `WindowsAdminCenter` | If using WAC with Arc |

---

## 8. Arc Gateway reduced sets (reference only)

The full lists above apply regardless. If Arc Gateway (`arcgw-tp-poc-conn-eus-01`) is active, nodes route most traffic through the gateway and only require the FQDNs below directly. Open the full lists above at the FortiGate regardless — the gateway handles the reduction on the node side.

### Arc-enabled servers — 8 required FQDNs when using Arc Gateway

| Endpoint | Purpose |
|---|---|
| `<prefix>.gw.arc.azure.com` | Your Arc Gateway URL — **disable TLS inspection** |
| `management.azure.com` | ARM control channel |
| `login.microsoftonline.com` | Entra ID token acquisition |
| `eastus.login.microsoft.com` | Entra ID token acquisition |
| `gbl.his.arc.azure.com` | Global Arc cloud service endpoint |
| `eus.his.arc.azure.com` | East US Arc core control channel |
| `packages.microsoft.com` | Linux onboarding |
| `download.microsoft.com` | Windows install package |

> Scenarios that still need additional endpoints even with Arc Gateway active: Azure Monitor Agent, Arc-enabled data services, Key Vault cert sync, Hybrid Runbook Worker, Microsoft Defender, Windows Update.

### Arc-enabled Kubernetes — 9 required FQDNs when using Arc Gateway

| Endpoint | Purpose |
|---|---|
| `<prefix>.gw.arc.azure.com` | Your Arc Gateway URL — **disable TLS inspection** |
| `management.azure.com` | ARM control channel |
| `eastus.obo.arc.azure.com` | Cluster Connect |
| `login.microsoftonline.com` | Entra ID tokens |
| `eastus.login.microsoft.com` | Entra ID tokens |
| `gbl.his.arc.azure.com` | Global Arc cloud service endpoint |
| `eus.his.arc.azure.com` | East US Arc core control channel |
| `mcr.microsoft.com` | Pull Arc agent container images |
| `*.data.mcr.microsoft.com` | Pull Arc agent container images |

> AKS Arc port 40343 (bidirectional, AKS Arc subnet → cluster IP) is required when Arc Gateway is active — see Section 6.

> AMA does not route through Arc Gateway — those endpoints must always be allowed directly.

---

## Important constraints for this POC

- **No HTTPS inspection.** All endpoints in this document must be excluded from FortiGate SSL deep inspection. Create a dedicated SSL inspection exclusion profile.
- **Azure Local does not support Arc Private Link Scope.** All Arc endpoints must resolve to public IPs from cluster nodes, ARB, and management machines.
- **AKS Arc internet URLs are consolidated** into `azurelocal-endpoints.md` for Azure Local 2504+ deployments. The AKS Arc section above supplements that list — do not replace it.
- **`*.servicebus.windows.net`** requires WebSocket (wss) outbound on port 443 — verify the FortiGate application control policy allows wss traffic on this FQDN.
