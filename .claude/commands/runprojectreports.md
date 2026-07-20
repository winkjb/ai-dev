---
description: Run the project-management coordinator reports (flags, PM, resource)
---

Refresh the raw project pull from Autotask, then run all three project-management coordinator reports, in order (run from the repo root, using the PowerShell tool):

```
./project-management/01-coordinator/Get-CoordinatorProjectData.ps1
./project-management/01-coordinator/Export-CoordinatorFlagsReport.ps1
./project-management/01-coordinator/Export-CoordinatorPMReport.ps1
./project-management/01-coordinator/Export-CoordinatorResourceReport.ps1
```

Then, if all three ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-ReportEmail.ps1 -To "bwinklesky@servit.net","tmarsili@servit.net" -Subject "Project Management Coordinator Reports" -Attachments "project-management/01-coordinator/output/coordinator-project-flags-detail.csv","project-management/01-coordinator/output/coordinator-project-flags-summary.csv","project-management/01-coordinator/output/coordinator-project-pm-detail.csv","project-management/01-coordinator/output/coordinator-project-pm-summary.csv","project-management/01-coordinator/output/coordinator-project-resource-detail.csv","project-management/01-coordinator/output/coordinator-project-resource-summary.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether each report ran successfully and whether the email sent, or the error(s) if any failed.
