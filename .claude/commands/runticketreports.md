---
description: Run the service-delivery ticket coordinator report
---

Refresh the raw ticket pull from Autotask, then run the service-delivery ticket report, in order (run from the repo root, using the PowerShell tool):

```
./service-delivery/01-coordinator/Get-CoordinatorTicketData.ps1
./service-delivery/01-coordinator/Export-CoordinatorTicketFlagsReport.ps1
```

Then, if the report ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-ReportEmail.ps1 -To "bwinklesky@servit.net","rpardue@servit.net" -Subject "Service Delivery Coordinator Reports" -Attachments "service-delivery/01-coordinator/output/coordinator-ticket-flags-detail.csv","service-delivery/01-coordinator/output/coordinator-ticket-flags-summary.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether the report ran successfully and whether the email sent, or the error(s) if either failed.

(`Invoke-CoordinatorReports.ps1` in the same folder does both of these steps unattended, for scheduled/automated runs.)
