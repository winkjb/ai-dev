param(

    # Search and analysis variables

    [string[]]$ExcludedUsers,
    [switch]$LogExclusions,
   
    # Output options

    [switch]$Logging,
    [string[]]$ToEmailAddr
    
)

$SettingsPath = Join-Path $PSScriptRoot "..\data\reference\CustomerSettings.txt"
$LogFile = Join-Path $PSScriptRoot "..\data\output\UserInfo.csv"

# System settings and variables

$Date = Get-Date -Format yyyy-MM-dd
$BatchSize = 20
$CountExclusions = 0
$CostCenterLookup = @{}
$MailboxUsage = @{}
$ResourceMailboxes = @{}
$Licenses = @()
$Users = @()
$Mailboxes = @()
$UserCostCenter = @()
$UsersManager = @()
$Results = @()

# Import settings

. "C:\PS\Scripts\VA-Functions.ps1"

# Start processing

$StartTime = Get-Date

# Import settings and acquire token

$CustomerSettings = Import-CustomerSettings -SettingsPath $SettingsPath
$Token = Get-GraphToken -CustomerSettings $CustomerSettings
$Headers = @{ Authorization = "Bearer $Token" }

# Get licenses

$Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
$Licenses = Get-AllResults -Uri $Uri -Headers $Headers

# Get users and create a cost center hashtable for quick lookups

$Uri = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,proxyAddresses,id,customSecurityAttributes,accountEnabled,assignedLicenses,createdDateTime,companyName,department,employeeId,employeeType,jobTitle,officeLocation,signInActivity&`$expand=manager"
$Users = Get-AllResults -Uri $Uri -Headers $Headers
$CountUsers = $Users.Count

foreach ($User in $Users) { if ($User.customSecurityAttributes.EmployeeData.CostCenter) { $CostCenterLookup[$User.userPrincipalName] = $User.customSecurityAttributes.EmployeeData.CostCenter } }

# Get mailbox report, convert results to a PowerShell object, and create a mailbox hashtable for quick lookups

$Uri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D30')" 
$Mailboxes = Invoke-RestMethod -Uri $Uri -Headers $Headers | ConvertFrom-Csv -Delimiter ','

foreach ($Mailbox in $Mailboxes) { $MailboxUsage[$Mailbox."User Principal Name"] = $Mailbox }

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

# Iterate through the list of users 

$i = 0
$Results = foreach ($User in $Users) {

    $i++

    Write-Progress -activity "Processing..." -status "$i out of $CountUsers completed" -PercentComplete ([int](($i/$CountUsers)*100))

    # Identify exclusions
    
    $InDynamicExclusion = $ResourceMailboxes.ContainsKey($User.id)   
    $InManualExclusion = ( $ExcludedUsers -contains $User.UserPrincipalName -or $User.DisplayName -like "(Admin)*" -or $User.DisplayName -like "(Service)*" -or $User.DisplayName -like "(Test)*" -or $User.DisplayName -like "(Temp)*" -or $User.DisplayName -like "Restore *" -or $User.DisplayName -like "Diverzify *" )
    $InExclusion = ($InDynamicExclusion -or $InManualExclusion)

    # Ignore manually excluded accounts

    if ( $InExclusion -eq $true ) { $InExclusion = $true }
        
    # Log finding

    if (-not $InExclusion -or $LogExclusions) {
    
        foreach ($License in $User.assignedLicenses) {
            $FriendlyLicense = Get-FriendlyLicenseName($Licenses | Where-Object { $_.skuId -eq $License.SkuId } | Select skuPartNumber -ExpandProperty skuPartNumber)
            $AllLicenses += $FriendlyLicense
        }

        $PrimarySmtp = $User.proxyAddresses | Where-Object {$_ -clike "SMTP:*" }
        $CostCenter = if ($User.customSecurityAttributes.EmployeeData.CostCenter) { $User.customSecurityAttributes.EmployeeData.CostCenter } else { $null }
        $UserLicenses = $AllLicenses -join ","
        $UsersManager = $User.manager.displayName
        $ManagerAccountEnabled = $User.manager.accountEnabled
        $ManagersCostCenter = if ($UsersManager) { $CostCenterLookup[$User.manager.userPrincipalName] } else { $null }
    
        $MailboxInfo = $MailboxUsage[$User.UserPrincipalName]
        if ($MailboxInfo) {     
            $StorageUsedGb = [math]::Round($MailboxInfo.'Storage Used (Byte)' / 1000000000, 2) 
            $StorageMaxGb = [math]::Round($MailboxInfo.'Prohibit Send/Receive Quota (Byte)' / 1000000000, 2)
            $StoragePercentage = [math]::Round(($StorageUsedGb / $StorageMaxGb) * 100)
        } else {
            $StorageUsedGb = "N/A" 
            $StorageMaxGb = "N/A"
            $StoragePercentage = "N/A"
        }

        $Finding = [ordered] @{ 
            
            Date                         = $Date
            UserPrincipalName            = $User.UserPrincipalName
            DisplayName                  = $User.DisplayName
            PrimarySmtp                  = $PrimarySmtp
            AccountEnabled               = $User.accountEnabled
            Created                      = $User.createdDateTime
            CompanyName                  = $User.companyName
            Department                   = $User.department
            EmployeeId                   = $User.employeeId
            CostCenter                   = $CostCenter
            EmployeeType                 = $User.employeeType
            JobTitle                     = $User.jobTitle
            OfficeLocation               = $User.officeLocation
            Manager                      = $UsersManager
            ManagerAccountEnabled        = $ManagerAccountEnabled
            ManagerCostCenter            = $ManagersCostCenter
            UserLicenses                 = $UserLicenses
            StorageUsedGb                = $StorageUsedGb
            StorageMaxGb                 = $StorageMaxGb
            StoragePercentage            = $StoragePercentage
            LastSuccessfulLogonDate      = $User.signInActivity.lastSuccessfulSignInDateTime
            LastNonInteractiveLogonDate  = $User.SignInActivity.LastNonInteractiveSignInDateTime
            
        }

        if ($LogExclusions) { $Finding.InExclusionGroup = if ($InExclusion) {"Y"} else {$null} }

        [PSCustomObject]$Finding

        $AllLicenses = @()

    }

}

# End processing

$EndTime = Get-Date
$TotalTime = ($EndTime-$StartTime).TotalSeconds
$Minutes = "{0:N0}" -f ($TotalTime/60)
$Seconds = "{0:N0}" -f ($TotalTime%60)

Write-Host "`r`nAudit conducted on Azure AD users in $Minutes minutes and $Seconds seconds.`r`n"

Write-Host "$CountUsers user(s) audited."
Write-Host "$CountExclusions user(s) excluded."
Write-Host $Results.count "user(s) identified."

# Log results

Ensure-Directory ($LogFile)
$Results | Sort DisplayName | Export-CSV -Path $LogFile -NoTypeInformation 
Write-Host "CSV File created at $LogFile.`r`n"