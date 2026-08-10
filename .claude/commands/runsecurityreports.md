---
description: Run the security team's Huntress escalations coordinator report
---

Run the security coordinator escalations report (run from the repo root, using the PowerShell tool):

```
./security/01-coordinator/Export-CoordinatorEscalationsReport.ps1
```

Then, if the report ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-EmailMessage.ps1 -To "bwinklesky@servit.net" -Subject "Security Coordinator Report" -Attachments "security/01-coordinator/output/coordinator-escalations-detail.csv","security/01-coordinator/output/coordinator-escalations-summary.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether the report ran successfully and whether the email sent, or the error(s) if either failed.

(`Invoke-CoordinatorReports.ps1` in the same folder does both of these steps unattended, for scheduled/automated runs.)
