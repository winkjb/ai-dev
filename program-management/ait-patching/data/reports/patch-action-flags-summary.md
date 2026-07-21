# AIT Patch Action Flags - Summary

Workstations and laptops (no servers) in Patch Status Failed or Not Installed, excluding unpatchable Windows 10 devices (EOL) unless the customer has an ESU agreement, and excluding customers on the ignore list.

- Flagged devices (unique, across all locations): 1192
- Locations needing a ticket (Customer + Site): 141
- Windows 10 rows excluded as unpatchable (no ESU): 108
- Windows Server rows excluded (out of scope - workstations/laptops only): 127
- Flagged rows with no OS match in Network Hardware (kept, flagged as unmatched): 1
- Customers currently on the ESU list: Brindlee Fire Services*, Soteria Flexibles (HQ)*
- Customers skipped entirely (ignore list): Diverzify Intermediate*, InReach Community DX

## Locations by device count (top 20)

| Customer | Site | Flagged Devices |
|---|---|---|
| Brindlee Fire Services* | Brindlee Fire Services | 87 |
| Beckway | No Site | 85 |
| Castles Tech | No Site | 52 |
| ServIT | No Site | 47 |
| SECO (HQ Southeast Consolidators) | No Site | 46 |
| Soteria Flexibles (HQ)* | Continental Products (Mexico, MO) | 40 |
| Soteria Flexibles (HQ)* | Hamilton Plastics Inc | 34 |
| Brindlee Fire Services* | PIMA Admin \| Fleet | 32 |
| Brindlee Fire Services* | Capstone Station 1 Admin | 30 |
| Brindlee Fire Services* | Yuma Admin | 29 |
| Ameriserve* | Ameriserve HQ (Tucker, GA) | 28 |
| Soteria Flexibles (HQ)* | FilmTech LLC | 26 |
| Galt Pharmaceuticals, LLC. | No Site | 25 |
| Brindlee Fire Services* | Knoxville Station 41 \| Admin | 23 |
| MRP a ServIT Company | No Site | 23 |
| German American Chamber of Commerce* | German American Chamber of Commerce (HQ) | 22 |
| J&A Engineering LLC | No Site | 22 |
| Worley, Schilling & Randall | No Site | 22 |
| General Wholesale* | General Wholesale Beer Company (615) (HQ) | 21 |
| General Wholesale* | General Wholesale Beer Company (1595) | 19 |

Ticket-ready detail (one row per device, grouped by location): patch-action-flags-by-location.csv  
Full detail (one row per flagged patch category): patch-action-flags-detail.csv