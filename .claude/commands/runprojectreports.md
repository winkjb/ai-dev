---
description: Run the project-management coordinator reports (flags, PM, resource)
---

Run all three project-management coordinator reports, in order:

```
cd project-management/01-coordinator
python project_summary_flags.py
python project_summary_pm.py
python project_summary_resource.py
```

Then, if all three ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-ReportEmail.ps1 -To "bwinklesky@servit.net","tmarsili@servit.net" -Subject "Project Management Coordinator Reports" -Attachments "project-management/01-coordinator/output/coordinator-project-flags-detail.csv","project-management/01-coordinator/output/coordinator-project-flags-summary.csv","project-management/01-coordinator/output/coordinator-project-pm-detail.csv","project-management/01-coordinator/output/coordinator-project-pm-summary.csv","project-management/01-coordinator/output/coordinator-project-resource-detail.csv","project-management/01-coordinator/output/coordinator-project-resource-summary.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether each report ran successfully and whether the email sent, or the error(s) if any failed.
