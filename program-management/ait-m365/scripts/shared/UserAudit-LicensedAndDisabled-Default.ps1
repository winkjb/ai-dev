################################################################################################################### 
##
## This script looks for licensed and disabled users in Entra ID
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
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$BatchSize = 20
$CountUsers = 0
$CountExclusions = 0
$CountResults = 0
$i = 0
$SkuHt = @{}
$ResourceMailboxes = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraUserAudit-LicensedAndDisabled.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

#Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users and page results

$Uri = "https://graph.microsoft.com/beta/users?`$select=id,displayName,userPrincipalName,createdDateTime,accountEnabled,assignedLicenses,signInActivity"
try { 
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
} catch {
    $Uri = "https://graph.microsoft.com/beta/users?`$select=id,displayName,userPrincipalName,createdDateTime,accountEnabled,assignedLicenses"
    $Users = Get-AllResults -Uri $Uri -Headers $Headers
}

# Filter the list of users 

$Users = $Users.Where({ ($_.AccountEnabled -eq $false) -and ($_.assignedLicenses) })
$CountUsers = $Users.count

# Get licenses, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($License in $Licenses) { $SkuHt[$License.skuId] = $License.skuPartNumber }

# Identify shared/resource mailboxes

for ($i = 0; $i -lt $CountUsers; $i += $BatchSize) {

    $UserSlice = $Users[$i..([math]::Min($i + $BatchSize - 1, $CountUsers - 1))]
        
    # Build one batch request body with a sub-request per user
    
    $Requests = @()
    foreach ($User in $UserSlice) {
    
        $Requests += @{

            id     = $User.id # use user id as request id
            method = "GET"
            url    = "/users/$($User.id)/mailboxSettings?`$select=userPurpose" 
        
        }
    
    }

    $Body = @{ requests = $Requests } | ConvertTo-Json -Depth 5
    $ApiResponse = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers $Headers -Body $Body -ContentType "application/json"

    # Find only 200s (has mailbox) and whose purpose is NOT a user
    
    foreach ($Response in $ApiResponse.responses) {
        
        if ($Response.status -eq 200 -and $Response.body.userPurpose -and $Response.body.userPurpose -ne 'user') {
            
            $ResourceMailboxes[$Response.id] = [PSCustomObject]@{
            
                Purpose  = $Response.body.userPurpose
                Source   = "MailboxPurpose"     
            
            }
 
        }
        
    }

}

# Audit users

$i = 0
$Results = foreach ($User in $Users) {

    $i++

    Write-Progress -activity "Processing..." -Status "$i out of $CountUsers completed" -PercentComplete ([int](($i/$CountUsers)*100))

    # Identify exclusions

    $InExclusion = $ExcludedUsers -contains $User.userPrincipalName

    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {
    
        # Normalize licenses

        $UserLicenses = ($User.assignedLicenses | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join ","

        # Normalize mailbox details 

        $CreatedDate = $User.createdDateTime
        $DaysAgo = Get-DaysSince $CreatedDate
        $IsSharedMailbox = $ResourceMailboxes.ContainsKey($User.id)
        $LoginDaysAgo = Get-DaysSince (Get-LatestDate @($User.signInActivity.lastSuccessfulSignInDateTime,$User.SignInActivity.lastNonInteractiveSignInDateTime))
 
        # Normalize finding

        $Finding = [ordered] @{

            Date                         = $Date
            DisplayName                  = $User.DisplayName
            UPN                          = $User.UserPrincipalName
            AccountEnabled               = $User.AccountEnabled
            UserLicenses                 = $UserLicenses
            IsSharedMailbox              = $IsSharedMailbox
            CreatedDate                  = $CreatedDate
            DaysAgo                      = $DaysAgo
            LastSuccessfulLogonDate      = $User.signInActivity.lastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate  = $User.SignInActivity.LastNonInteractiveSignInDateTime
            LoginDaysAgo                 = $LoginDaysAgo
            Issue                        = "User is licensed and disabled"
            Action                       = "Reclaim license"   
        
        }
        
        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++

    }

}

#End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra ID users in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountUsers disabled user(s) audited."
Write-Host "$CountExclusions user(s) excluded."
Write-Host "$CountResults issue(s) identified."

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
    
        if ($Results) { $Body="CSV Attached for $Date<br>" } else { $Body="No CSV Attached for $Date - No Results<br>" }
    
        $Body+="

        Audit conducted on Entra ID users in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountUsers disabled user(s) audited.<br>
        $CountExclusions user(s) excluded.<br>
        $CountResults issue(s) identified.<br>
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
        $Subject     = "Entra User Audit - Licensed and Disabled"
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