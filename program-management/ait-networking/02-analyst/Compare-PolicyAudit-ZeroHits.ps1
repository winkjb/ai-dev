<#
.SYNOPSIS
    Analyst: reads a site's collected firewall policy/VIP snapshot
    (../01-collector/Collect-FirewallPolicies.ps1's raw output) and flags policies and VIPs with
    zero hit count - candidates for cleanup/removal. Does not call the FortiGate API - that's the
    collector's job.

.DESCRIPTION
    Writes two findings files since policies and VIPs are different row shapes: PolicyAudit-
    ZeroHits.csv and VipAudit-ZeroHits.csv. Both are always written, even with zero findings
    (header-only), so a clean site produces a legitimate empty result rather than a missing file.

.EXAMPLE
    .\Compare-PolicyAudit-ZeroHits.ps1 -Directory katz\hq
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [string]$PoliciesRawPath,
    [string]$VipsRawPath,
    [string]$OutputDir
)

if (-not $PoliciesRawPath) { $PoliciesRawPath = Join-Path $PSScriptRoot "..\data\raw\$Directory\FirewallPolicies.csv" }
if (-not $VipsRawPath)     { $VipsRawPath     = Join-Path $PSScriptRoot "..\data\raw\$Directory\FirewallVips.csv" }
if (-not $OutputDir)       { $OutputDir       = Join-Path $PSScriptRoot "output\$Directory" }

. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-VA-Common.ps1")
. (Join-Path $PSScriptRoot "..\..\..\scripts\Functions-Formatting-Common.ps1")

$Now = Get-Date

# --- load -----------------------------------------------------------------

$Policies = @(Import-Csv -LiteralPath $PoliciesRawPath -Encoding UTF8)
$Vips = @(Import-Csv -LiteralPath $VipsRawPath -Encoding UTF8)

# --- flag -------------------------------------------------------------------

$FlaggedPolicies = @($Policies.Where({ [int]$_.HitCount -eq 0 }))

$PolicyResults = @(foreach ($Policy in ($FlaggedPolicies | Sort-Object { [int]$_.PolicyId })) {
    [PSCustomObject][ordered]@{
        Date     = $Now.ToString("yyyy-MM-dd")
        PolicyId = $Policy.PolicyId
        Name     = $Policy.Name
        SrcIntf  = $Policy.SrcIntf
        DstIntf  = $Policy.DstIntf
        Action   = $Policy.Action
        Status   = $Policy.Status
    }
})

$FlaggedVips = @($Vips.Where({ (-not $_.TotalHitCount) -or [int]$_.TotalHitCount -eq 0 }))

$VipResults = @(foreach ($Vip in ($FlaggedVips | Sort-Object VipName)) {
    [PSCustomObject][ordered]@{
        Date            = $Now.ToString("yyyy-MM-dd")
        VipName         = $Vip.VipName
        ExtIp           = $Vip.ExtIp
        MappedIp        = $Vip.MappedIp
        Interface       = $Vip.Interface
        RelatedPolicies = $Vip.RelatedPolicies
    }
})

Test-Directory $OutputDir
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "PolicyAudit-ZeroHits.csv") -InputObject @($PolicyResults)
Export-Utf8NoBomCsv -Path (Join-Path $OutputDir "VipAudit-ZeroHits.csv") -InputObject @($VipResults)

Write-Host "$($Policies.Count) polic(y/ies) in raw snapshot, $($PolicyResults.Count) with zero hit count."
Write-Host "$($Vips.Count) VIP(s) in raw snapshot, $($VipResults.Count) with zero hit count."
Write-Host "Findings written to $OutputDir"
