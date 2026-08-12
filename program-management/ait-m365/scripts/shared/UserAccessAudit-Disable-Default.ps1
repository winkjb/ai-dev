################################################################################################################### 
##
## This script conducts a user access review in Azure Active Directory
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
    [int]$LessThanDays,
    [switch]$LogUnlicensedUsers,
    [switch]$LogGuests,
    [switch]$LogExclusions,
    [switch]$Testing,
    
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
$SkuHt = @{}
$ResourceMailboxes = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraUserAccessAudit-Disable.csv"

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

# Get users and page results

$Uri = "https://graph.microsoft.com/beta/users?`$select=DisplayName,UserPrincipalName,Id,AccountEnabled,createdDateTime,signInActivity,assignedLicenses"
$Users = Get-AllResults -Uri $Uri -Headers $Headers

# Filter the list of users 

$DateCutoff = ($StartTime.AddDays(-$LessThanDays)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$Users = $Users.Where({ ($_.accountEnabled -eq $true) -and ($_.createdDateTime -le $DateCutoff) -and ($_.signInActivity.lastSuccessfulSignInDateTime -le $DateCutoff) -and ($_.signInActivity.lastNonInteractiveSignInDateTime -le $DateCutoff) })
if ($LogUnlicensedUsers -eq $false) { $Users = $Users.Where({ $_.assignedLicenses.Count -gt 0 }) }
if ($LogGuests -eq $false) { $Users = $Users.Where({ $_.UserPrincipalName -notlike "*#EXT#*" }) }
$CountUsers = $Users.Count

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

    Write-Progress -activity "Processing..." -status "$i out of $CountUsers completed" -PercentComplete ([int](($i/$CountUsers)*100))

    # Identify exclusions
    
    $InDynamicExclusion = $ResourceMailboxes.ContainsKey($User.id)   
    $InManualExclusion = $ExcludedUsers -contains $User.UserPrincipalName
    $InExclusion = ($InDynamicExclusion -or $InManualExclusion)

    if ($InExclusion) { $CountExclusions++ }

    # Log finding

    if (-not $InExclusion -or $LogExclusions) {
    
        # Normalize licensing  

        $UserLicenses = ($User.assignedLicenses | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join ","  
    
        # Normalize activity
        
        $LastSuccessfulLogonDate = $User.signInActivity.lastSuccessfulSignInDateTime
        $LastNonInteractiveLogonDate = $User.signInActivity.lastNonInteractiveSignInDateTime
        $DaysAgo = Get-DaysSince (Get-LatestDate @($LastSuccessfulLogonDate,$LastNonInteractiveLogonDate))
        
        # Normalize finding

        $Finding = [ordered] @{
            
            Date                         = $Date
            DisplayName                  = $User.DisplayName
            UPN                          = $User.UserPrincipalName
            CreatedDate                  = $User.createdDateTime
            LastSuccessfulLogonDate      = $LastSuccessfulLogonDate
            LastNonInteractiveLogonDate  = $LastNonInteractiveLogonDate
            DaysAgo                      = $DaysAgo
            UserLicenses                 = $UserLicenses
            Issue                        = if (-not $InExclusion) {"Last logon more than $LessThanDays days ago"} else {$null}
            Action                       = if (-not $InExclusion) {"Disable user"} else {$null}
            ActionTaken                  = $null
        
        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $CountResults++
        
    }

}

# For testing, announce what would have happened

if ($Testing -eq $true) {
    foreach ($User in $Results) { if ($User.Action -eq "Disable user") { Write-Host "Testing Mode:" $User.UPN "would be disabled." } }
}

# For execution, take action on aged users (For Future Development)

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Entra ID users in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountUsers user(s) audited."
Write-Host "$CountExclusions user(s) excluded."
Write-Host "$CountResults user(s) identified."

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
        $CountUsers user(s) audited.<br>
        $CountExclusions user(s) excluded.<br>
        $CountResults user(s) identified.<br>
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
        $Subject     = "Entra User Access Audit - $LessThanDays Days Inactive"
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