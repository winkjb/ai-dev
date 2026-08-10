---
description: Run the Diverzify user report
---

Run this script from this repository (using the PowerShell tool):

```
./program-management/ait-m365/diverzify/scripts/Invoke-DiverzifyUserReport.ps1

```

Then, if the report ran successfully, email the results (run from the repo root, using the PowerShell tool):

```
./scripts/Send-EmailMessage.ps1 -To "bwinklesky@servit.net","nleverett@servit.net" -Subject "Diverzify User Report" -Attachments "program-management/ait-m365/diverzify/data/output/UserInfo.csv"
```

Don't summarize the output data or open the resulting files. Just report back whether the report ran successfully and whether the email sent, or the error(s) if either failed.
