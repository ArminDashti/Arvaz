---
name: dpdc-tune-sql-scripts
description: >-
  Use when the user asks to tune, optimize, or speed up a SQL Server script on the DPDC / Pakhsh database (stored procedure, function, view, trigger, ad-hoc query, or batch script). Captures baseline results from recent data, tunes for performance only, requires identical output before keeping the change, rolls back on any mismatch, and ends with a change list and an Old / New / Diff % table. Not for bug fixes or edits without a performance goal.
author: "Armin Dashti"
uuid: 569f85e0-1c63-4b52-9d22-dfa36d6f514c
---
# DPDC Tune SQL Scripts

## Rules

1. **Results never change.** Same columns, rows, and values. Tune only for speed (plan, indexes, set-based rewrites, parameter sniffing, removing wasted work).
2. **Parity is a hard gate.** Any baseline vs. after mismatch means roll back to the original definition.
3. **Same inputs** for baseline and after-tune runs.
4. **Recent data.** Sample parameters from new rows (latest dates / IDs) unless the user names a dataset.
5. **20 samples per scenario** by default, one CSV per sample, never merged.
6. **Safe by default.** Follow `dpdc-db-policy`; read-only sampling; ask before any other data-changing DML.
7. **Ask when unsure** (scenarios, working folder, cleanup).

## Steps

1. **Lock the target.** Object (`schema.name`) or file, database, connection. Save the current definition (`OBJECT_DEFINITION`) for rollback. List parameters.
2. **Define scenarios.** Split real usage into distinct parameter shapes (date range, status, customer class, page size).
3. **Baseline.** In `.armin/tmp/sp-tune-<schema>-<name>/`:

   | Folder | Contents |
   |--------|----------|
   | `inputs/` | `<scenario>-<nn>.json` parameter values |
   | `baseline/` | `<scenario>-<nn>.csv` result of the current script, plus `manifest.csv` with time / reads / CPU |
   | `after/` | Same names, tuned script results |
   | `compare/` | Mismatch reports |

4. **Optimize.** Apply the change (`ALTER PROCEDURE` and/or index DDL) only after baseline exists.
5. **After-tune.** Re-run the same inputs into `after/`, recording timings the same way.
6. **Compare.** Each pair must match exactly, row by row. If the script has no `ORDER BY`, sort both sides on a stable key and say so. Write mismatches to `compare/`. Mismatch means roll back.
7. **Report** (always, even after a rollback):

```markdown
What was changed:
1. <change>
2. <change>

| Old performance | New performance | Diff % |
|-----------------|-----------------|--------|
| <old> | <new> | <diff> |
```

   - One data row only, same unit on both sides (e.g. average ms across samples).
   - `Diff % = (Old - New) / Old x 100`, one decimal; positive means faster. `N/A` with a short reason if no timings.
   - After a rollback, list what was tried and state it was rolled back.

8. **Cleanup.** Keep the folder if the user asked to store samples; otherwise ask before deleting it.

## Example

Tune `dbo.usp_OrderList` with scenarios "open" and "closed": 40 inputs, 40 baseline CSVs, replace a cursor with a set-based JOIN and add an index, 40 matching after CSVs, then:

```markdown
What was changed:
1. Replaced cursor loop with set-based JOIN in dbo.usp_OrderList.
2. Added index IX_Orders_Status_Date on dbo.Orders (Status, OrderDate) INCLUDE (CustomerId).

| Old performance | New performance | Diff % |
|-----------------|-----------------|--------|
| 1200 ms avg | 450 ms avg | 62.5% |
```