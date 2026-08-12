################################################################################################################### 
##
## This script audits Entra Conditional Access Policy Exclusion Groups
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExpectedGroupInteractive,
    [string[]]$ExpectedGroupGeography,
    [string[]]$ExpectedGroupMfa,
    [string[]]$ExpectedGroupModern,
    [switch]$LogExpectedUsers,
    [switch]$LogDisabledUsers,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountGroups = 0
$CountResults = 0
$GroupHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraGroupMemberAudit-ConditionalAccess.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Define additional functions

function Compare-ExpectedGroupMembers {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedGroupMembers,
        [Parameter(Mandatory)][hashtable]$GroupHt,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Date,
        [switch]$LogDisabledUsers,
        [switch]$LogExpectedUsers
    )

    $GroupResults = @()
    $MemberHt = @{}

    $GroupId = $GroupHt[$GroupName]

    if (-not $GroupId) {

        $GroupResults += [PSCustomObject][ordered]@{
            Date            = $Date
            Group           = $GroupName
            UPN             = $null
            CreatedDateTime = $null
            DaysAgo         = $null
            AccountEnabled  = $null
            Issue           = "Group name not found"
        }

        Write-Host "$GroupName not found."
        $Script:CountResults++
        return $GroupResults
    
    }

    $Uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.user?`$select=id,displayName,userPrincipalName,createdDateTime,accountEnabled"
    $GroupMembers = Get-AllResults -Uri $Uri -Headers $Headers

    if ($GroupMembers) {

        # Build a hashtable for reference later

        foreach ($Member in $GroupMembers) {

            $MemberHt[$Member.userPrincipalName] = [PSCustomObject]@{
                CreatedDateTime = $Member.createdDateTime
                AccountEnabled  = [bool]$Member.accountEnabled
            }
        }

        # Filter group members

        $ActualGroupMembers = @(if ($LogDisabledUsers) {
            $GroupMembers | Select-Object -ExpandProperty userPrincipalName
        } else {
            $GroupMembers | Where-Object { $_.accountEnabled } | Select-Object -ExpandProperty userPrincipalName
        })

    } else {

        $ActualGroupMembers = @()
    }

    $Comparison = Compare-Object -ReferenceObject $ExpectedGroupMembers -DifferenceObject $ActualGroupMembers
    
    # Log expectations
    
    if ($LogExpectedUsers) {

        $MatchedGroupMembers = @($ActualGroupMembers | Where-Object { $_ -in $ExpectedGroupMembers })

        foreach ($UPN in $MatchedGroupMembers) {

            $CreatedDate = $MemberHt[$UPN].CreatedDateTime
            $DaysAgo = Get-DaysSince $CreatedDate
            $AccountEnabled = $MemberHt[$UPN].AccountEnabled

            $GroupResults += [PSCustomObject][ordered]@{
                Date           = $Date
                Group          = $GroupName
                UPN            = $UPN
                CreatedDate    = $CreatedDate
                DaysAgo        = $DaysAgo
                AccountEnabled = $AccountEnabled
                Issue          = "User is in group, In expected group"
            }
        
        }
    
    }
            
    if (-not $Comparison) {

        Write-Host "$GroupName is correct."
        return $GroupResults
    }

    Write-Host "$GroupName is NOT correct."
    
    # Log differences

    foreach ($Difference in $Comparison) {

        $UPN = $Difference.InputObject
        $CreatedDate = $MemberHt[$UPN].CreatedDateTime
        $DaysAgo = Get-DaysSince $CreatedDate
        $AccountEnabled  = $MemberHt[$UPN].AccountEnabled
        
        $GroupResults += [PSCustomObject][ordered]@{
            
            Date            = $Date
            Group           = $GroupName
            UPN             = $UPN
            CreatedDate     = $CreatedDate
            DaysAgo         = $DaysAgo
            AccountEnabled  = $AccountEnabled
            Issue           = if ($Difference.SideIndicator -eq "=>") { "User is in group, Not in expected group" } elseif ($Difference.SideIndicator -eq "<=") { "User is in expected group, Not in group" }
        
        }
        
        $Script:CountResults++

    }

    return $GroupResults

}

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get groups, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/groups?`$select=Id,DisplayName"
$AllGroups = Get-AllResults -Uri $Uri -Headers $Headers 

foreach ($Group in $AllGroups) { $GroupHt[$Group.DisplayName] = $Group.id }

# Define the groups to audit

$GroupsToAudit = @(

    [PSCustomObject]@{
        GroupName            = "Block Interactive Login Group"
        ExpectedGroupMembers = $ExpectedGroupInteractive
    }
    [PSCustomObject]@{
        GroupName            = "Geo-IP Fencing Exclusion Group"
        ExpectedGroupMembers = $ExpectedGroupGeography
    }
    [PSCustomObject]@{
        GroupName            = "MFA Exclusion Group"
        ExpectedGroupMembers = $ExpectedGroupMfa
    }
    [PSCustomObject]@{
        GroupName            = "Modern Authentication Exclusion Group"
        ExpectedGroupMembers = $ExpectedGroupModern
    }

)

# Audit groups

foreach ($Group in $GroupsToAudit) {

    $CountGroups++

    $GroupResults = Compare-ExpectedGroupMembers `
        -GroupName $Group.GroupName `
        -ExpectedGroupMembers $Group.ExpectedGroupMembers `
        -GroupHt $GroupHt `
        -Headers $Headers `
        -Date $Date `
        -LogDisabledUsers:$LogDisabledUsers `
        -LogExpectedUsers:$LogExpectedUsers

    if ($GroupResults) { $Results += $GroupResults }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra Conditional Access Exclusion Group(s) in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountGroups group(s) audited."
Write-Host "$CountResults issue(s) encountered."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object Group,UPN | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s)

        $body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $body+="    
        Audit conducted on Entra Conditional Access Exclusion Group(s) in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountGroups group(s) audited.<br>
        $CountResults issue(s) encountered.<br>
        <br>
        <br>
        ##############################<br>
        Source: Virtual Administrator<br>
        Customer Folder: $CustomerFolder<br>
        ##############################<br>
        "

        # Format the email parameters

        $SmtpServer  = $CustomerSettings.SmtpServer
        $Port        = $CustomerSettings.SmtpPort
        $From        = $CustomerSettings.SmtpFrom
        $To          = $ToEmailAddr
        $Subject     = "Entra Group Member Audit - Conditional Access Exclusions"
        $Body        = $Body
        $UseSsl      = $CustomerSettings.SmtpSsl -eq "Yes"

        if ($Results) { $Attachment = $LogFile } else { $Attachment = $null }
       
        if ( ($CustomerSettings.SmtpUsername -ne "") -and ($CustomerSettings.SmtpPassword -ne "") ) { 
    
            $SmtpPassword = ConvertTo-SecureString $CustomerSettings.SmtpPassword -AsPlainText -Force
            $Credentials = New-Object System.Management.Automation.PSCredential($CustomerSettings.SmtpUsername, $SmtpPassword)

        } else {

           $Credentials = $null 

        }

        # Send the email

        Send-Results -SmtpServer $SmtpServer -Port $Port -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml $true -UseSsl $UseSsl -Credential $Credentials -Attachment $Attachment

    }

}