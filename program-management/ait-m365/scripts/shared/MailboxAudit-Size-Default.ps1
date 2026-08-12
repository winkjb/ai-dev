################################################################################################################### 
##
## This script audits mailbox size
## Version 2.5
##
################################################################################################################### 

param(

    # Search and analysis variables

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Directory,
    [string]$CustomerFolder,
    [int]$StorageMoreThan,
    
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$CountMailboxes = 0
$i = 0
$CountResults = 0
$UserHt = @{}
$SkuHt = @{}
$Results = @()

# Derived settings and variables

$BasePath = "C:\PS\$Directory"
$SettingsPath = Join-Path $BasePath "Settings\CustomerSettings.txt"
$LogFile = Join-Path $BasePath "Logs\EntraMailboxAudit-Size.csv"

# Import functions

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get users, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/beta/users?`$select=userPrincipalName,assignedLicenses"
$Users = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($User in $Users) { $UserHt[$User.userPrincipalName] = $User.assignedLicenses }

# Get licenses, page results and build a hashtable for reference later

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

foreach ($License in $Licenses) { $SkuHt[$License.skuId] = $License.skuPartNumber }

# Get mailbox report and convert to a PowerShell object

$Uri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D30')" 
$Mailboxes = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

# Filter the list of mailboxes

$Mailboxes = foreach ($Mailbox in $Mailboxes) { 

    if ($Mailbox."Is Deleted" -eq $true) { continue }

    $Mailbox

}
$CountMailboxes = @($Mailboxes).count

# Audit mailbox storage

$Results = foreach ($Mailbox in $Mailboxes) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountMailboxes completed" -PercentComplete ([int](($i/$CountMailboxes)*100))

    # Normalize mailbox usage

    $StorageUsedGb = [math]::Round($Mailbox.'Storage Used (Byte)' / 1000000000, 2) 
    $StorageMaxGb = [math]::Round($Mailbox.'Prohibit Send/Receive Quota (Byte)' / 1000000000, 2)
    $StoragePercentage = if ($StorageMaxGb -gt 0) { [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100, 2) } else { $null } 

    # Log finding

    if ($StoragePercentage -ge $StorageMoreThan) {

        # Normalize licenses

        try { $UserLicensing = $UserHt[$Mailbox.'User Principal Name'] } catch {}
        try { $UserLicenses = ($UserLicensing | ForEach-Object { Get-FriendlyLicenseName -sku $SkuHt[$_.skuId] } | Sort-Object ) -join "," } catch {}

        # Normalize finding

        [PSCustomObject][ordered] @{ 
        
            Date               = $Date
            DisplayName        = $Mailbox.'Display Name'
            UPN                = $Mailbox.'User Principal Name'
            UserLicenses       = $UserLicenses
            HasArchive         = $Mailbox.'Has Archive'
            StorageUsedGb      = $StorageUsedGb
            StorageMaxGb       = $StorageMaxGb
            StoragePercentage  = $StoragePercentage 
        
        }
        
    $CountResults++
    
    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on mailboxes in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountMailboxes mailbox(es) audited."
Write-Host "$CountResults issue(s) identified."

# Log results

if ($Logging -eq $true) {

    if ($LogFile) {

        # Export log file

        Ensure-Directory ($LogFile)
        $Results | Sort-Object StoragePercentage -Descending | Export-CSV -Path $LogFile -NoTypeInformation 
        Write-Host "CSV File created at $LogFile.`r`n"

    }

    if ($ToEmailAddr) {
    
        # Email the CSV and stats to admin(s) 

        $Body = ""
    
        if ($Results) { $Body+= "CSV Attached for $Date<br>" } else { $Body+="No CSV Attached for $Date - No Results<br>" }

        $Body+="
        Audit conducted on mailboxes in $Minutes minutes and $Seconds seconds.<br>
        <br>
        $CountMailboxes mailbox(es) audited.<br>
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
        $Subject     = "Mailbox Size Audit - over $StorageMoreThan% usage"
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