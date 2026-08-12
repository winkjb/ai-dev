################################################################################################################### 
##
## This script looks for Entra users that appear to be temporary
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [string[]]$ExcludedUsers,
    [switch]$EnabledUsersOnly,
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountUsers = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$SkuHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraUserAudit-TempUsers.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users and page results

$Uri = "https://graph.microsoft.com/beta/users?`$select=DisplayName,UserPrincipalName,createdDateTime,AccountEnabled,assignedLicenses,signInActivity"
try { 
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
} catch {
    $Uri = "https://graph.microsoft.com/beta/users?`$select=DisplayName,UserPrincipalName,createdDateTime,AccountEnabled,assignedLicenses"
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
}

# Filter the list of users 

$Users = foreach ($User in $Users) {
    
    if ( ($EnabledUsersOnly -eq $true) -and ($User.AccountEnabled -eq $false) ) { continue }
    if ( ($User.DisplayName -notlike "*test*") -and ($User.DisplayName -notlike "*temp*") -and ($User.UserPrincipalName -notlike "*test*") -and ($User.UserPrincipalName -notlike "*temp*") ) { continue }

    $User

}
$CountUsers = @($Users).Count

# Get licenses, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($License in $Licenses) { $SkuHt[$License.skuId] = $License.skuPartNumber }

# Audit users

$Results = foreach ($User in $Users) {
    
    $i++

    Write-Progress -activity "Processing..." -Status "$i out of $CountUsers completed" -PercentComplete ([int](($i/$CountUsers)*100))

    # Identify exclusions

    $InExclusion = $ExcludedUsers -contains $User.UserPrincipalName

    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {
    
        # Normalize licenses

        $UserLicenses = ($User.assignedLicenses | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join ","

        # Normalize details

        $CreatedDate = $User.createdDateTime
        $DaysAgo = Get-DaysSince $CreatedDate
        $LoginDaysAgo = Get-DaysSince (Get-LatestDate @($User.signInActivity.lastSuccessfulSignInDateTime,$User.SignInActivity.lastNonInteractiveSignInDateTime))

        # Normalize finding

        $Finding = [ordered]@{

            Date                         = $Date
            DisplayName                  = $User.DisplayName
            UPN                          = $User.UserPrincipalName
            CreatedDate                  = $CreatedDate
            DaysAgo                      = $DaysAgo
            LastSuccessfulLogonDate      = $User.signInActivity.lastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate  = $User.signInActivity.lastNonInteractiveSignInDateTime
            LoginDaysAgo                 = $LoginDaysAgo
            UserLicenses                 = $UserLicenses
            AccountEnabled               = $User.AccountEnabled
        
        }
        
        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++

    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra ID users in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountUsers temp user(s) audited."
Write-Host "$CountExclusions user(s) excluded."
Write-Host "$CountResults temp user(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

    # Export log file

    Ensure-Directory ($LogFile)
    $Results | Sort-Object DisplayName | Export-CSV -Path $LogFile -NoTypeInformation 
    Write-Host "CSV File created at $LogFile.`r`n"
    
    }

    if ($ToEmailAddr) {

        # Email the CSV and stats to admin(s)

        $Body=""

        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="

        Audit conducted on Entra ID users in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountUsers temp user(s) audited.<br>
        $CountExclusions user(s) excluded.<br>
        $CountResults temp user(s) identified.<br>
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
        $Subject     = "Entra User Audit - Temp Users"
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