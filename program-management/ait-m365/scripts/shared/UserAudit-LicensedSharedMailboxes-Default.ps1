################################################################################################################### 
##
## This script looks for shared mailboxes that are licensed in Entra ID
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
$SkuHt = @{}
$MailboxHt = @{}
$ResourceMailboxes = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraUserAudit-LicensedSharedMailboxes.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

#Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users and page results

$Uri = "https://graph.microsoft.com/beta/users?`$select=id,displayName,userPrincipalName,AccountEnabled,AssignedLicenses"
$Users = Get-AllResults -Uri $Uri -Headers $Headers 

# Filter the list of users 

$Users = $Users.Where({ $_.assignedLicenses })
$CountUsers = $Users.count

# Get licenses, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($License in $Licenses) { $SkuHt[$License.skuId] = $License.skuPartNumber }

# Get mailbox report, convert results to a PowerShell object and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D30')" 
$Mailboxes = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

foreach ($Mailbox in $Mailboxes) { $MailboxHt[$Mailbox."User Principal Name"] = $Mailbox }

# Identify shared mailboxes

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

    # Find only 200s (has mailbox) and whose purpose is shared
    
    foreach ($Response in $ApiResponse.responses) {
        
        if ($Response.status -eq 200 -and $Response.body.userPurpose -and $Response.body.userPurpose -eq 'shared') {
            
            $ResourceMailboxes[$Response.id] = [PSCustomObject]@{
            
                Purpose  = $Response.body.userPurpose
                Source   = "MailboxPurpose"     
            
            }
 
        }
        
    }

}

#Audit users 

$i=0
$Results = foreach ($User in $Users) {
    
    $i++

    Write-Progress -activity "Processing..." -Status "$i out of $CountUsers completed" -PercentComplete ([int](($i/$CountUsers)*100))

    # Identify exclusions

    $IsSharedMailbox = $ResourceMailboxes.ContainsKey($User.id)
    $InExclusion = $ExcludedUsers -contains $User.UserPrincipalName

    if ($IsSharedMailbox -and $InExclusion) { $CountExclusions++ }

    # Log finding

    if ($IsSharedMailbox -and (-not $InExclusion -or $LogExclusions)) {
    
        # Normalize licenses

        $UserLicenses = ($User.assignedLicenses | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join ","
        
        # Normalize mailbox details 

        $MailboxDetails = $MailboxHt[$User.userPrincipalName]
        $StorageUsedGb = [math]::Round($MailboxDetails.'Storage Used (Byte)' / 1000000000, 2) 
        $StorageMaxGb = [math]::Round($MailboxDetails.'Prohibit Send/Receive Quota (Byte)' / 1000000000, 2)
        $StoragePercentage = [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100)
        $LastActivityDate = $MailboxDetails.'Last Activity Date'
        $DaysAgo = Get-DaysSince $LastActivityDate
             
        # Normalize finding
                        
        $Finding = [ordered]@{

            Date                = $Date
            DisplayName         = $User.DisplayName
            UPN                 = $User.UserPrincipalName
            UserLicenses        = $UserLicenses
            StorageUsedGb       = $StorageUsedGb
            StorageMaxGb        = $StorageMaxGb
            StoragePercentage   = $StoragePercentage
            LastActivityDate    = $LastActivityDate
            DaysAgo             = $DaysAgo
            Issue               = "User is licensed and a shared mailbox"
            Action              = "Reclaim license" 
        
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

Write-Host "$CountUsers licensed user(s) audited."
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
        $CountUsers licensed user(s) audited.<br>
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
        $Subject     = "Entra User Audit - Licensed Shared Mailboxes"
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