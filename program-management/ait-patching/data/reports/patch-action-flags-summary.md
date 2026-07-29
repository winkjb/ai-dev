# AIT Patch Action Flags - Summary

Workstations and laptops (no servers) in Patch Status Failed or Not Installed, excluding unpatchable Windows 10 devices (EOL) unless the customer has an ESU agreement, and excluding customers on the ignore list.

- Flagged devices (unique, across all locations): 807
- Locations needing a ticket (Customer + Site): 132
- Windows 10 rows excluded as unpatchable (no ESU): 43
- Windows Server rows excluded (out of scope - workstations/laptops only): 0
- Flagged rows with no OS match in Network Hardware (kept, flagged as unmatched): 45
- Customers currently on the ESU list: Brindlee Fire Services*, Soteria Flexibles (HQ)*
- Customers skipped entirely (ignore list): Diverzify Intermediate*, InReach Community DX

## Locations by device count (top 20)

| Customer | Site | Flagged Devices |
|---|---|---|
| Brindlee Fire Services* | Brindlee Fire Services | 87 |
| Beckway | No Site | 57 |
| Castles Tech | No Site | 40 |
| Brindlee Fire Services* | PIMA Admin \| Fleet | 27 |
| Boxercraft* | Unknown (not in Network Hardware) | 26 |
| Brindlee Fire Services* | Yuma Admin | 26 |
| Brindlee Fire Services* | Capstone Station 1 Admin | 25 |
| SECO (HQ Southeast Consolidators) | No Site | 24 |
| Worley, Schilling & Randall | No Site | 23 |
| Ameriserve* | Ameriserve HQ (Tucker, GA) | 22 |
| Galt Pharmaceuticals, LLC. | No Site | 21 |
| Brindlee Fire Services* | Central AZ Station 857 Admin | 16 |
| Brindlee Fire Services* | Knoxville Station 41 \| Admin | 16 |
| German American Chamber of Commerce* | German American Chamber of Commerce (HQ) | 16 |
| Soteria Flexibles (HQ)* | Continental Products (Mexico, MO) | 16 |
| Brindlee Fire Services* | Central AZ Fleet (Tempe, AZ) | 15 |
| Patriot Select Property and Casualty Ins. Co.* | Patriot Select Co. | 14 |
| Soteria Flexibles (HQ)* | Hamilton Plastics Inc | 13 |
| General Wholesale* | General Wholesale Beer Company (615) (HQ) | 12 |
| SKL'D Staffing Holdco, LLC* | SKL'D Staffing (Duluth, GA) | 11 |

Ticket-ready detail (one row per device, grouped by location): patch-action-flags-by-location.csv  
Full detail (one row per flagged patch category): patch-action-flags-detail.csv