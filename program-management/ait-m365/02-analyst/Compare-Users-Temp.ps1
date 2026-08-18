<#
.SYNOPSIS
    Analyst: compares a customer's collected Entra user list
    (../01-collector/Collect-EntraUsers.ps1's raw snapshot) against the internal "looks
    temporary" naming baseline and writes flagged findings, with each user's licenses resolved
    from ../01-collector/Collect-EntraLicenses.ps1's raw license catalog. Does not call Graph and
    does not email - that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-UserAudit-Temp.ps1).

.DESCRIPTION
    A user is flagged if their DisplayName or UPN contains "test" or "temp" (case-insensitive) -
    the same heuristic as ../02-analyst/Compare-Groups-Temp.ps1, applied to users instead of
    groups. Unlike that script, there's no "Templates" exception here - the original
    UserAudit-TempUsers-Default.ps1 monolith never had one for users.

    -EnabledUsersOnly drops disabled accounts from consideration entirely (matches the original
    monolith's switch of the same name) - off by default, so both enabled and disabled temp-named
    accounts are flagged.

    Users listed in data/reference/<Directory>/excluded-temp-users.csv (matched by UPN) are
    dropped from the findings by default. Pass -IncludeExclusions to keep them in the output
    instead, marked via an IsExcluded column - same convention as
    ../02-analyst/Compare-Groups-Temp.ps1.

.EXAMPLE
    .\Compare-Users-Temp.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [switch]$EnabledUsersOnly,

    [string]$UsersPath,
    [string]$LicenseCatalogPath,
    [string]$ExclusionsPath,
    [string]$OutputPath,
    [switch]$IncludeExclusions
)

if (-not $UsersPath)          { $UsersPath          = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraUsers.csv" }
if (-not $LicenseCatalogPath) { $LicenseCatalogPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraLicenses-Usage.csv" }
if (-not $ExclusionsPath)     { $ExclusionsPath     = Join-Path $PSScriptRoot "..\data\reference\$Directory\excluded-temp-users.csv" }
if (-not $OutputPath)         { $OutputPath         = Join-Path $PSScriptRoot "output\$Directory\UserAudit-Temp.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-M365-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Users = @(Import-Csv -LiteralPath $UsersPath -Encoding UTF8)
$Catalog = @(Import-Csv -LiteralPath $LicenseCatalogPath -Encoding UTF8)
$ExclusionRows = if (Test-Path -LiteralPath $ExclusionsPath) { @(Import-Csv -LiteralPath $ExclusionsPath -Encoding UTF8) } else { @() }
$ExcludedUpns = @($ExclusionRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

$SkuNameById = @{}
foreach ($License in $Catalog) { $SkuNameById[$License.SkuId] = $License.SkuPartNumber }

$SignInActivityAvailable = if ($Users) { ($Users[0].SignInActivityAvailable -eq "Y") } else { $true }

# --- flag -------------------------------------------------------------------

$Candidates = @($Users.Where({
    (-not $EnabledUsersOnly -or ($_.AccountEnabled -eq "True")) `
    -and (($_.DisplayName -like "*test*") -or ($_.DisplayName -like "*temp*") -or ($_.UserPrincipalName -like "*test*") -or ($_.UserPrincipalName -like "*temp*"))
}))

$CountExclusions = 0

$Results = foreach ($User in $Candidates) {

    $IsExcluded = $ExcludedUpns -contains $User.UserPrincipalName
    if ($IsExcluded) { $CountExclusions++ }

    if (-not $IsExcluded -or $IncludeExclusions) {

        $UserLicenses = if ($User.AssignedSkuIds) {
            (($User.AssignedSkuIds -split ",") | ForEach-Object { Get-FriendlyLicenseName -sku $SkuNameById[$_] } | Sort-Object) -join ","
        } else { $null }

        $CreatedDate = $User.CreatedDate
        $DaysAgo = Get-DaysSince -Value $CreatedDate -Reference $Now
        $LoginDaysAgo = Get-DaysSince -Value (Get-LatestDate @($User.LastSuccessfulSignInDateTime, $User.LastNonInteractiveSignInDateTime)) -Reference $Now

        $Finding = [ordered]@{
            DisplayName                  = $User.DisplayName
            UPN                          = $User.UserPrincipalName
            CreatedDate                  = $CreatedDate
            DaysAgo                      = $DaysAgo
            LastSuccessfulLogonDate      = $User.LastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate  = $User.LastNonInteractiveSignInDateTime
            LoginDaysAgo                 = $LoginDaysAgo
            UserLicenses                 = $UserLicenses
            AccountEnabled               = $User.AccountEnabled
        }
        if ($IncludeExclusions) { $Finding.IsExcluded = if ($IsExcluded) {"Y"} else {$null} }
        [PSCustomObject]$Finding

    }

}

$Results = @($Results | Sort-Object DisplayName)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$($Users.Count) user(s) in raw snapshot."
Write-Host "$($Candidates.Count) user(s) matched the temp/test naming pattern."
Write-Host "$CountExclusions user(s) excluded via $(Split-Path $ExclusionsPath -Leaf)."
if (-not $SignInActivityAvailable) { Write-Host "Note: signInActivity wasn't available for this pull - logon dates will be blank." -ForegroundColor Yellow }
Write-Host "Findings written to $OutputPath"
