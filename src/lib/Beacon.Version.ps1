# AzL Beacon - single source of truth for version strings. Dot-sourced by every in-image script.
# The line below is bumped by release-please (see release-please-config.json extra-files).
$script:BeaconVersion = '1.1.0' # x-release-please-version

# Results JSON contract version (docs/reference/results.schema.json). Bump on breaking changes only.
$script:BeaconSchemaVersion = '1.1'

# Azure Local release train the endpoint data and checks are written against.
$script:BeaconReleaseTrain = '12.2609 (latest)'

# Tested WinPE build inputs. Build-WinPEImage.ps1 records what it actually found in build-manifest.json.
$script:BeaconAdkExpectation = @{
    AdkVersionPrefix   = '10.1.26100'   # Windows ADK for Windows 11, version 24H2 / 25H2 line
    WinPEAddonRequired = $true
}
