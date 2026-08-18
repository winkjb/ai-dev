<#
.SYNOPSIS
    Analyst: compares a customer's collected Conditional Access exclusion group membership
    (../01-collector/Collect-EntraGroupMembers-CA.ps1's raw snapshot) against the expected
    membership baseline for each group and writes flagged findings. Does not call Graph and
    does not email - that's the collector's and the customer wrapper's job, respectively (see
    ../katz/Invoke-GroupMemberAudit-CA.ps1).

.DESCRIPTION
    -CaGroups maps each audited CA group's display name to the data/reference/<Directory>/*.csv
    file holding its expected membership (a single UPN column) - defaults to the 4-group
    baseline from the original katz/Invoke-GroupMemberAudit-CA-Default.ps1 script; override
    per-call for a customer with different group names or a different set of groups.

    Each row is flagged with an Issue:
      - Group name not found - the collector couldn't find the group at all (GroupFound=N in
        the raw snapshot)
      - In group, not in expected list - actual member has no matching UPN in that group's
        reference CSV
      - In expected list, not in group - reference CSV lists a UPN Graph didn't return as a
        current member
      - Matches expected list - only emitted when -IncludeExpectedMatches is passed

    Disabled-account members are dropped from the "actual" side by default (matches the
    original script's -LogDisabledUsers behavior) - pass -IncludeDisabledUsers to keep them.

.EXAMPLE
    .\Compare-GroupMembers-CA.ps1 -Directory katz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    # Baseline as of the original katz/Invoke-GroupMemberAudit-CA-Default.ps1 script (retired
    # 2026-08-16) - override per-call if a customer needs different CA groups or reference files.
    [hashtable[]]$CaGroups = @(
        @{ GroupName = "Block Interactive Login Group";         ReferenceFile = "expected-ca-exclusions-interactive.csv" }
        @{ GroupName = "Geo-IP Fencing Exclusion Group";        ReferenceFile = "expected-ca-exclusions-geography.csv" }
        @{ GroupName = "MFA Exclusion Group";                   ReferenceFile = "expected-ca-exclusions-mfa.csv" }
        @{ GroupName = "Modern Authentication Exclusion Group"; ReferenceFile = "expected-ca-exclusions-modernauth.csv" }
    ),

    [string]$RawPath,
    [string]$ReferenceDir,
    [string]$OutputPath,

    [switch]$IncludeDisabledUsers,
    [switch]$IncludeExpectedMatches
)

if (-not $RawPath)      { $RawPath      = Join-Path $PSScriptRoot "..\data\raw\$Directory\EntraGroupMembers-CA.csv" }
if (-not $ReferenceDir) { $ReferenceDir = Join-Path $PSScriptRoot "..\data\reference\$Directory" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $PSScriptRoot "output\$Directory\GroupMemberAudit-CA.csv" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Raw = @(Import-Csv -LiteralPath $RawPath -Encoding UTF8)
$RawByGroup = @{}
foreach ($Row in $Raw) { Add-ToIndex -Index $RawByGroup -Key $Row.GroupName -Value $Row }

# --- audit ------------------------------------------------------------------

$CountGroups = 0
$CountIssues = 0

$Results = foreach ($CaGroup in $CaGroups) {

    $CountGroups++
    $GroupName = $CaGroup.GroupName
    $GroupRows = @($RawByGroup[$GroupName])

    if (-not $GroupRows -or $GroupRows[0].GroupFound -ne "Y") {

        Write-Host "$GroupName not found." -ForegroundColor Yellow
        $CountIssues++
        [PSCustomObject][ordered]@{
            Group          = $GroupName
            UPN            = $null
            CreatedDate    = $null
            DaysAgo        = $null
            AccountEnabled = $null
            Issue          = "Group name not found"
        }
        continue

    }

    $ReferencePath = Join-Path $ReferenceDir $CaGroup.ReferenceFile
    $ExpectedRows = if (Test-Path -LiteralPath $ReferencePath) { @(Import-Csv -LiteralPath $ReferencePath -Encoding UTF8) } else { @() }
    $ExpectedUpns = @($ExpectedRows | ForEach-Object { $_.UPN } | Where-Object { $_ })

    $MemberRows = @($GroupRows | Where-Object { $_.UPN })
    $MemberByUpn = @{}
    foreach ($Member in $MemberRows) { $MemberByUpn[$Member.UPN] = $Member }

    $ActualUpns = @(if ($IncludeDisabledUsers) {
        $MemberRows | Select-Object -ExpandProperty UPN
    } else {
        $MemberRows | Where-Object { $_.AccountEnabled -eq "True" } | Select-Object -ExpandProperty UPN
    })

    if ($IncludeExpectedMatches) {

        $MatchedUpns = @($ActualUpns | Where-Object { $_ -in $ExpectedUpns })

        foreach ($UPN in $MatchedUpns) {
            $Member = $MemberByUpn[$UPN]
            [PSCustomObject][ordered]@{
                Group          = $GroupName
                UPN            = $UPN
                CreatedDate    = $Member.CreatedDate
                DaysAgo        = Get-DaysSince -Value $Member.CreatedDate -Reference $Now
                AccountEnabled = $Member.AccountEnabled
                Issue          = "Matches expected list"
            }
        }

    }

    $Comparison = Compare-Object -ReferenceObject $ExpectedUpns -DifferenceObject $ActualUpns

    if (-not $Comparison) {
        Write-Host "$GroupName is correct."
        continue
    }

    Write-Host "$GroupName is NOT correct." -ForegroundColor Yellow

    foreach ($Difference in $Comparison) {

        $UPN = $Difference.InputObject
        $Member = $MemberByUpn[$UPN]

        $CountIssues++

        [PSCustomObject][ordered]@{
            Group          = $GroupName
            UPN            = $UPN
            CreatedDate    = $Member.CreatedDate
            DaysAgo        = Get-DaysSince -Value $Member.CreatedDate -Reference $Now
            AccountEnabled = $Member.AccountEnabled
            Issue          = if ($Difference.SideIndicator -eq "=>") { "In group, not in expected list" } else { "In expected list, not in group" }
        }

    }

}

$Results = @($Results | Sort-Object Group, UPN)

Test-Directory (Split-Path $OutputPath -Parent)
Export-Utf8NoBomCsv -Path $OutputPath -InputObject $Results

Write-Host "$CountGroups CA exclusion group(s) audited."
Write-Host "$CountIssues issue(s) encountered."
Write-Host "$($Results.Count) finding(s) written to $OutputPath"
