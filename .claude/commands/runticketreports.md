---
description: Run the service-delivery ticket coordinator report
---

Run the service-delivery ticket report:

```
cd service-delivery/01-coordinator
python ticket_summary_flags.py
```

Then, if the report ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-ReportEmail.ps1 -To "bwinklesky@servit.net","rpardue@servit.net" -Subject "Service Delivery Coordinator Reports" -Attachments "service-delivery/01-coordinator/output/coordinator-ticket-flags-detail.csv","service-delivery/01-coordinator/output/coordinator-ticket-flags-summary.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether the report ran successfully and whether the email sent, or the error(s) if either failed.
