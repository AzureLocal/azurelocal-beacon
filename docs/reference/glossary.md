# Glossary

| Term | Definition |
|---|---|
| **AzL Beacon** | This tool — a WinPE bootable Azure Local pre-deployment validation image |
| **WinPE** | Windows Preinstallation Environment — a lightweight Windows runtime that boots from ISO/USB without a full OS install |
| **iDRAC** | Integrated Dell Remote Access Controller — provides virtual media mounting used to boot Beacon on Dell servers |
| **SBE** | Solution Builder Extension — a Dell-provided package containing drivers, firmware, and plugins for Azure Local |
| **Local Identity** | Azure Local deployment mode using local admin + Azure Key Vault instead of Active Directory |
| **LCM user** | Lifecycle Management user account — the AD deployment user used by Azure Local's deployment and servicing engine |
| **OU** | Organizational Unit — the dedicated Active Directory container required for Azure Local's computer objects |
| **ADAware** | Cluster property: 0=None, 1=AD-joined, 2=Local Identity (workgroup cluster) |
| **Arc** | Azure Arc — the Azure management plane used to register and manage Azure Local nodes |
| **EnvChecker** | `AzStackHci.EnvironmentChecker` — the official Microsoft PowerShell module for Azure Local environment readiness |
| **SSL deep-inspection** | A firewall feature that intercepts and re-signs TLS sessions; incompatible with Azure Local deployment |
| **APIPA** | Automatic Private IP Addressing — `169.254.x.x` addresses assigned when DHCP fails; indicates no network |
| **DISM** | Deployment Image Servicing and Management — the Windows tool used to inject drivers into the WinPE boot.wim |
| **copype** | WinPE script (`copype.cmd`) that creates the WinPE workspace skeleton |
