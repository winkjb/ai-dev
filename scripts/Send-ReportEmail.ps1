###################################################################################################################
##
## Opt-in helper to email report output (e.g. coordinator CSV/MD files) using the shared SMTP settings in
## data/reference/SmtpSettings.csv. Not wired into any report run automatically - call it explicitly.
##
## Example:
##   ./scripts/Send-ReportEmail.ps1 -To "brad.winklesky@gmail.com" -Subject "Ticket flags report" `
##       -Attachments "service-delivery/01-coordinator/output/coordinator-ticket-flags-summary.csv"
##
###################################################################################################################

param(
    [Parameter(Mandatory)]
    [string[]]$To,

    [Parameter(Mandatory)]
    [string]$Subject,

    [string[]]$Attachments,

    [string]$Body = "See attached report output.",

    [bool]$BodyAsHtml = $false,

    # Falls back to data/reference/SmtpSettings.csv (sibling of this script's scripts/ folder)
    [string]$SettingsPath = $(Join-Path $PSScriptRoot "..\data\reference\SmtpSettings.csv")
)

$CommonScript = Join-Path $PSScriptRoot "VA-Functions-Common.ps1"
if (-not (Test-Path -LiteralPath $CommonScript)) {
    Write-Error "Shared functions script not found: $CommonScript"
    exit 1
}
. $CommonScript

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Error "SMTP settings file not found: $SettingsPath"
    exit 1
}

$Settings = Import-Csv -LiteralPath $SettingsPath | Select-Object -First 1
if (-not $Settings) { throw "No rows found in $SettingsPath" }

$UseSsl = $Settings.SmtpSsl -match '^(yes|true|1)$'

$Credentials = $null
if ($Settings.SmtpUsername) {
    $SecurePassword = ConvertTo-SecureString $Settings.SmtpPassword -AsPlainText -Force
    $Credentials = New-Object System.Management.Automation.PSCredential($Settings.SmtpUsername, $SecurePassword)
}

Send-Results `
    -SmtpServer $Settings.SmtpServer `
    -Port ([int]$Settings.SmtpPort) `
    -From $Settings.SmtpFrom `
    -To $To `
    -Subject $Subject `
    -Body $Body `
    -BodyAsHtml $BodyAsHtml `
    -UseSsl $UseSsl `
    -Attachments $Attachments `
    -Credentials $Credentials
