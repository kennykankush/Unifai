# Payment reliability and MCP verification

Verified October 21, 2026, in the working tree based on 78b53bb. This receipt covers local implementation, not a published release.

## Automated checks

| Check | Observed result |
| --- | --- |
| Offline Swift suite | 118 discovered; 110 passed, 8 opt-in checks skipped; no failures |
| Optimized Swift build | Passed; existing onChange deprecation warning remains |
| Debug MCP stdio check | All 12 tools returned structured results |
| Optimized MCP stdio check | All 12 tools returned structured results |
| Invalid arguments and unknown write tool | Rejected |
| Corrupt MCP input file | Reported an error and preserved the file |
| MCP data integrity | Input hash and directory contents unchanged by queries |
| Diff whitespace check | Passed |

Commands:

```sh
bash scripts/swift-local.sh test
bash scripts/swift-local.sh build -c release
python3 scripts/check-mcp.py
python3 scripts/check-mcp.py .build/release/unifai-mcp
git diff --check
```

Regression coverage includes repeated top-ups before and after confirmation; a manual receipt within the observation interval; an unrelated older payment; one-to-one receipt replacement; duplicate re-import; ambiguous imports leaving memory and disk unchanged; wallet-label disambiguation; and invoice reconciliation without recreating month-end estimates.

Backup tests cover prior-state retention, private file permissions, unchanged saves, blocked backup writes, bounded retention, traversal refusal and recovery with the corrupt original preserved.

Spending and agent tests cover signed refunds, estimated and scheduled payments, accruing usage, matching budget arithmetic, missing currencies, exchange-rate dates, partial-month exclusions, account filtering, pagination, malformed arguments, repeated future renewals, overdue schedules and stale/failed capacity.

## Native UI observations

Used .build/Unifai Review.app, explicitly configured for synthetic data in .qa/reliability-review. Provider transports were fixture-only. The fixture Keychain diagnostic was disabled. The installed Unifai remained running separately.

| Action | Observed result |
| --- | --- |
| Combine currencies and open monthly breakdown | Overview and sheet both showed 201.48 SGD: 177.71 confirmed plus 23.77 accruing |
| Switch to all history | Sheet showed 651.45 SGD, matching the overview |
| Inspect conversion rows | Original USD/CNY amounts and dated reference-rate explanations visible |
| Escape | Closed breakdown and returned to the main app |
| Resize main window | Checked standard 1400-wide and minimum 1180-wide layouts; breakdown entry remained accessible |
| Settings → Review Local Backups | Saved copies showed date, payment count and wallet count |
| Restore one synthetic copy | Confirmation displayed, restore succeeded, both settings sheets closed, restored currency setting visible |
| Inspect restored workspace | Previous state file retained under a preserved backup name |
| Open wallet with synthetic detected top-up | Before/after evidence and Confirm/Edit actions visible |
| Confirm synthetic top-up | Estimate label disappeared; payment count stayed unchanged; evidence and confirmation timestamp remained in JSON |
| Edit from wallet | Existing record opened with amount, currency and receipt reference; cancelled without changing it |

The preview app was closed after checks. Its synthetic workspace remains available for review. No production data, real credentials, purchases, provider refreshes, signing setup or external releases were changed.

## Limits

No live integration check ran. The checks do not establish App Store compatibility, macOS 14 hardware behavior, full VoiceOver operation or light-appearance qualification.

Backups are local JSON, not off-device recovery. New detection evidence does not reconstruct observations missing from old records. Ambiguous receipt matches require review. Renewal outlook uses saved schedules and current reference rates; it is not a variable-usage forecast.
