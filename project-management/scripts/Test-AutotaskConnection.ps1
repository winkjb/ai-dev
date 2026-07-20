<#
.SYNOPSIS
    Verifies the Autotask REST API credentials in data/reference/AutotaskSettings.txt
    are valid and reachable - no project data is pulled, just a connectivity check.

.DESCRIPTION
    Uses the shared scripts/Autotask-Functions-Common.ps1 library (Connect-Autotask,
    Invoke-AutotaskQuery) to run a minimal, read-only Projects query and confirm auth
    succeeds end-to-end.

.EXAMPLE
    .\Test-AutotaskConnection.ps1
#>

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$KeyPath
)

$FunctionsScript = Join-Path $PSScriptRoot "..\..\scripts\Autotask-Functions-Common.ps1"
if (-not (Test-Path -LiteralPath $FunctionsScript)) {
    Write-Error "Shared functions script not found: $FunctionsScript"
    exit 1
}
. $FunctionsScript

$ConnectParams = @{}
if ($SettingsPath) { $ConnectParams["SettingsPath"] = $SettingsPath }
if ($KeyPath) { $ConnectParams["KeyPath"] = $KeyPath }

Write-Host "Connecting to Autotask..." -ForegroundColor Cyan
try {
    $Connection = Connect-Autotask @ConnectParams
}
catch {
    throw "Connection failed: $($_.Exception.Message)"
}
Write-Host "Zone resolved: $($Connection.ZoneUrl)" -ForegroundColor Cyan

Write-Host "Testing authenticated Projects query..." -ForegroundColor Cyan
try {
    $Projects = Invoke-AutotaskQuery -Connection $Connection -Entity "Projects" -Filter @(
        @{ op = "gte"; field = "id"; value = 0 }
    ) -MaxRecords 5 -FirstPageOnly
}
catch {
    throw "Authenticated call failed: $($_.Exception.Message)"
}

Write-Host "Connection succeeded - credentials are valid." -ForegroundColor Green
Write-Host "Projects returned (sample): $($Projects.Count)" -ForegroundColor Green
$Projects | Select-Object -First 3 id, projectName, projectNumber, status | Format-Table
