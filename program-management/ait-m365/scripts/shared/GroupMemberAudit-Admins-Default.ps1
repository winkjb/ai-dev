################################################################################################################### 
##
## This script audits admins in Entra Active Directory
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$AdminGroups,
    [int]$LessThanDays,
    [switch]$LogDisabledUsers,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$EscalatedLicenses = $true
$CountGroups = 0
$CountResults = 0
$SkuHt = @{}
$RoleHt = @{}
$AdminHtByRole = @{}
$AdminHtByUpn = @{}
$UserHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraGroupMemberAudit-Admins.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get licenses, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($License in $Licenses) { $SkuHt[$License.skuId] = $License.skuPartNumber }

# Get admin roles, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions?`$select=id,displayName"
$Roles = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($Role in $Roles) { $RoleHt[$Role.DisplayName] = $Role.Id }

# Get admin users, page results and build hashtables for reference later

$Uri = "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?`$expand=principal"
$AllAdmins = Get-AllResults -Uri $Uri -Headers $Headers | Select roleDefinitionId -ExpandProperty Principal

foreach ($Admin in $AllAdmins) { 

    $Role = $Admin.roleDefinitionId
    $UPN  = $Admin.UserPrincipalName

    $Value = [PSCustomObject]@{
        UPN         = $Admin.UserPrincipalName     
        DisplayName = $Admin.DisplayName
    }

    # Role > users hashtable
    Add-ToIndex -Index $AdminHtByRole -Key $Role -Value $Value
    # User > roles hashtable
    Add-ToIndex -Index $AdminHtByUpn -Key $UPN -Value $Role

}

# Get users, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/beta/users?`$select=UserPrincipalName,createdDateTime,accountEnabled,assignedLicenses,signInActivity"
try { 
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
} catch {
    $Uri = "https://graph.microsoft.com/beta/users?`$select=UserPrincipalName,createdDateTime,accountEnabled,assignedLicenses"
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
    $EscalatedLicenses = $false
}

foreach ($User in $Users) { $UserHt[$User.userPrincipalName] = $User }

# Audit identified groups

$Results = foreach ($Group in $AdminGroups) {

	$Role = $RoleHt[$Group]
    $CountGroups ++
    
    $GroupMembers = $AdminHtByRole[$Role]

    foreach ($Member in $GroupMembers) {
        
        if ($Member.UPN) { 
            $MemberDetails = $UserHt[$Member.UPN] 
            $AdminType = "User"
        } else { 
            $MemberDetails = $null 
            $AdminType = $null
        }
        
        $Issue = @()

        # Analyze user status

        $UserEnabled = ( ($AdminType -eq "User") -and ($MemberDetails.AccountEnabled -eq $true) )
        $IsServiceAccount = $AdminType -ne "User"
        
        if ( ($AdminType -eq "User") -and (-not $UserEnabled) ) { $Issue += "Account disabled" }

        # Log finding

        if ($UserEnabled -or $IsServiceAccount -or $LogDisabledUsers) {
        
            $UPN = $Member.UPN
            $DisplayName = $Member.DisplayName
                        
            # Normalize licenses

            if ($MemberDetails.assignedLicenses) { 
                $UserLicenses = ($MemberDetails.assignedLicenses | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join ","
            } else { 
                $UserLicenses = $null
            }
                

            if ( ($AdminType -eq "User") -and ($UserLicenses) ) { $Issue += "Account licensed" }

            # Normalize user activity

            $CreatedDate = $MemberDetails.createdDateTime
            $DaysAgo = Get-DaysSince $CreatedDate
            $LoginDaysAgo = Get-DaysSince (Get-LatestDate @($MemberDetails.signInActivity.lastSuccessfulSignInDateTime,$MemberDetails.SignInActivity.lastNonInteractiveSignInDateTime))
            
            if ($EscalatedLicenses -eq $true) {
                if ( ($AdminType -eq "User") -and ($LoginDaysAgo -eq $null) ) { $Issue += "No logon recorded" }
                if ( ($AdminType -eq "User") -and ($LoginDaysAgo -ge $LessThanDays) ) { $Issue += "Last logon more than $LessThanDays days ago" }
            }

            # Normalize other conditions

            if ( ($AdminType -eq "User") -and ($Group -eq "Global Administrator") -and ($AdminHtByUpn[$MemberDetails.UserPrincipalName].count -gt 1) ) { $Issue += "Overlapping permissions" }
            if ( ($AdminType -eq "User") -and ($DisplayName -notmatch "Proofpoint Essentials|Quest On Demand") -and ($DisplayName -notlike "*admin*") -and ($UPN -notmatch "admin|servit") ) { $Issue += "Escalated user account" }            

            # Normalize finding

            [PSCustomObject][ordered] @{ 
        
                Date                         = $Date
                Group                        = $Group
                DisplayName                  = $DisplayName
                UPN                          = $UPN
                CreatedDate                  = $MemberDetails.createdDateTime
                DaysAgo                      = $DaysAgo
                LastSuccessfulLogonDate      = $MemberDetails.signInActivity.lastSuccessfulSignInDateTime
                LastNonInteractiveLogonDate  = $MemberDetails.SignInActivity.LastNonInteractiveSignInDateTime
                LoginDaysAgo                 = $LoginDaysAgo
                UserLicenses                 = $UserLicenses
                AccountEnabled               = if ($AdminType -eq "User") {$UserEnabled} else {$null} 
                Issue                        = $Issue -join ","
            
            }    
            
            $CountResults ++
        
        }
               
    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra Admin Group(s) in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountResults admin role(s) identified in $CountGroups group(s).`r`n"

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object Group,DisplayName | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s) 

        $Body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="    
        Audit conducted on Entra Admin Group(s) in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountResults admin role(s) identified in $CountGroups group(s).<br>
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
        $Subject     = "Entra Group Member Audit - Admins"
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