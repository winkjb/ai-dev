<#
.SYNOPSIS
    Analyst: shapes a customer's collected Entra user list
    (../01-collector/Collect-EntraUsers.ps1's raw snapshot, with resource/shared mailboxes
    resolved from ../01-collector/Collect-EntraMailboxPurpose.ps1's full-tenant snapshot for
    this audit) into a plain user roster for HR. Does not call Graph and does not email - that's
    the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-UserAudit-Hr.ps1).

.DESCRIPTION
    Guests (UPN containing "#EXT#") and resource/shared/room mailboxes are always excluded -
    matches the original script's unconditional filtering (not a switch there, so not one here
    either). Users listed in data/reference/<Directory>/excluded-hr-users.csv (matched by UPN)
    are dropped from the roster by default - pass -IncludeExclusions to keep them, marked via
    an Excluded column.

    Reporting-only - every in-scope user, not just flagged ones. No staleness/disable logic;
    see ../02-analyst/Compare-Users-Disable.ps1 for that.

.EXAMPLE
    .\Compare-Users-Hr.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$UsersPath,
    [string]$MailboxPurposePath,
    [string]$ExclusionsPath,
    [string]$OutputPath,

    [switch]$IncludeExclusions
)

if (-not $UsersPath)          { $UsersPath          = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }
if (-not $MailboxPurposePath) { $MailboxPurposePath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraMailboxPurpose-Hr.csv" }
if (-not $ExclusionsPath)     { $ExclusionsPath     = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-hr-users.csv" }
if (-not $OutputPath)         { $OutputPath         = Join-Path $PSScriptRoot "output\$Directory\UserAudit-Hr.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$MailboxPurposeRows = @(Import-Csv -LiteralPath $MailboxPurposePath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

$PurposeByUpn = @{}
foreach ($Row in $MailboxPurposeRows) { $PurposeByUpn[$Row.UPN] = $Row.Purpose }

# --- filter/shape -------------------------------------------------------------------

$InScope = @($Users.Where({ $_.UserPrincipalName -notlike "*#EXT#*" }))

$CountExclusions = 0
$CountResourceMailboxes = 0

$Results = foreach ($User in $InScope) {

    $Purpose = $PurposeByUpn[$User.UserPrincipalName]
    if ($Purpose -and ($Purpose -ne "user")) { $CountResourceMailboxes++; continue }

    $IsExcluded = $ExcludedUpns -contains $User.UserPrincipalName
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $Finding = [ordered]@{
            DisplayName = $User.DisplayName
            UPN         = $User.UserPrincipalName
            CreatedDate = $User.CreatedDate
            DaysAgo     = Get-DaysSince -Value $User.CreatedDate -Reference $Now
        }
        if ($IncludeExclusions) { $Finding.Excluded = if ($IsExcluded) { "Y" } else { $null } }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($InScope.Count) non-guest user(s) in raw snapshot."
Write-Host "$CountResourceMailboxes resource/shared mailbox(es) excluded."
Write-Host "$CountExclusions user(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
Write-Host "$($Results.Count) user(s) written to $OutputPath"
