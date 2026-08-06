###################################################################################################################
##
## Helper to email reports output using the shared SMTP settings in data/reference/SmtpSettings.csv. 
## Not wired into any report run automatically - call it explicitly.
##
## Example:
##   ./scripts/Send-EmailMessage.ps1 -To "brad.winklesky@gmail.com" -Subject "Ticket flags report" `
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

    [bool]$BodyAsHtml = $true,

    [string]$SettingsPath
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Import functions

$CommonFunctions = Join-Path $PSScriptRoot "Functions-VA-Common.ps1"
if (-not (Test-Path -LiteralPath $CommonFunctions)) {
    Write-Error "Shared functions script not found: $CommonFunctions"
    exit 1
}
. $CommonFunctions

# Set $SettingsPath if not passed 

if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "..\data\reference\SmtpSettings.csv" }

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Error "SMTP settings file not found: $SettingsPath"
    exit 1
}

# Import settings

$Settings = Import-Csv -LiteralPath $SettingsPath

if (-not $Settings) { throw "No rows found in $SettingsPath" }

$UseSsl = $Settings.SmtpSsl -match '^(yes|true|1)$'

$Credentials = $null
if ($Settings.SmtpUsername) {
    $SecurePassword = ConvertTo-SecureString $Settings.SmtpPassword -AsPlainText -Force
    $Credentials = New-Object System.Management.Automation.PSCredential($Settings.SmtpUsername, $SecurePassword)
}

# ---------------------------------------------------------------------------
# Send email 
# ---------------------------------------------------------------------------

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
