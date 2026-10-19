# Native milestone verification

Recorded on 2026-10-19 in `/Users/hamulia/dev/unifai`. This receipt separates fixture checks, live public access and unverified authenticated access. Native observations below were recorded from the computer-use accessibility tree and screenshots; no screenshot files are retained in this directory.

## Build and tests

| Check | Witnessed result | Receipt |
| --- | --- | --- |
| Toolchain | macOS 26.5 build 25F71, Xcode 26.0.1, Swift 6.2, Apple silicon | Tool output in development session |
| Debug executable | Build passed | `build.log` |
| Normal local app bundle | Build and local ad-hoc signing passed | `bundle.log` |
| Synthetic app bundle | Build and local ad-hoc signing passed | `fixture-bundle.log` |
| Optimized executable | Build passed | `release-build.log` |
| Full suite with integration opt-ins | 32 tests, 0 failures, 0 skips | `tests-final.log` |
| Anonymous public GitHub client | 50 releases from `swiftlang/swift`, one GET, no credential | `tests-final.log`, PublicGitHubTests |
| Native app Keychain check | Create, read, replace, isolate and delete passed in a unique synthetic service | `native-keychain-check.json` |
| Vision preservation | `VISION.md: OK` under SHA-256 verification | `vision-original.sha256` |

The full test command was:

```sh
UNIFAI_TEST_KEYCHAIN=1 UNIFAI_TEST_PUBLIC_GITHUB=1 \
  bash scripts/swift-local.sh test
```

Tests cover prepaid accounting, refunds, separate currencies, future payment rejection, duplicate references, strict numeric parsing, provider request routes and errors, anonymous conditional GitHub requests, safe release links, rate-limit headers, persistence and permissions, corrupt/future schema preservation, save failure, credential isolation, duplicate billing owners, in-flight refresh protection, cooldown persistence and concurrent backoff.

Earlier logs are retained. `tests.log` passed the offline tests and skipped Keychain. `keychain-tests.log` records OSStatus `-50` from the restricted test process. `tests-full-access.log` then passed all 30 tests present at that checkpoint, including Keychain. `tests-final.log` is the later 32-test result with the public GitHub smoke and concurrent-backoff coverage.

## Native workflow observations

Account creation and financial editing used the explicitly labelled **Unifai Fixtures** app. The normal app was inspected in its empty state. Fixture transports never instantiate a network session. Fixture records and diagnostic receipts stay in `.qa/fixture-workspace`.

| Workflow | Observed behavior |
| --- | --- |
| Normal empty launch | “Start with Your Accounts”, “No confirmed payments recorded”, “No payment history recorded”; no invented balances |
| Synthetic initial state | USD 120 and CNY 100 paid; partial history; no provider balances before refresh |
| OpenRouter refresh | USD 70 remaining, USD 100 reported purchased, USD 30 consumption, source link, observation timestamp and unknown consumption coverage start |
| DeepSeek refresh | CNY 110 remaining, CNY 10 promotional and CNY 100 purchased; no consumption history |
| Permission failure | Replacing a fixture key with `fixture-unauthorized` produced the permissions error while USD 70 and its original success timestamp remained |
| Payment validation | `1oops` produced “Enter an amount such as 100.00, using a decimal point.” without saving |
| Payment creation | Saved “Synthetic UI payment”, USD 12.34, receipt `SYNTHETIC-UI-004`; totals became USD 132.34 and CNY 100 |
| Subscription creation | Saved “Synthetic renewal”, USD 49 monthly; paid totals remained USD 132.34 and CNY 100 |
| Catalogue search | “DeepSeek” returned its supported entry; “X For You” returned a planned entry with no connection action |
| Multiple accounts | Saved “Synthetic Work” under DeepSeek with a separate billing owner; it remained distinct from “Personal” |
| Repository creation | Saved a local follow for `example/second-project`; no external GitHub watch or star changed |
| Release refresh | Displayed “Synthetic release”, `v1.0.0`, publication date and original GitHub link |
| Prerelease option | Enabling it added “Synthetic preview”, `v1.1.0-beta`, labelled Prerelease |
| Cooldown | Immediate second refresh showed “GitHub refresh available after 12:38 AM.” following the 12:08 AM refresh |
| Relaunch | Retained five accounts, USD 132.34/CNY 100, two schedules, snapshots, permission error, two follows and release cache |
| Accessibility labels | Balance detail labels and amounts were present together after the label fix; named buttons and native form labels were exposed |
| Window sizes | Inspected the standard 1120-by-760 window and the minimum-width layout, approximately 864 by 632 including window chrome; text wrapped and content scrolled |
| Compact form | All payment fields, Cancel and Save Payment remained visible; Escape dismissed the sheet |
| Menu bar companion | File > Show Companion opened a native status-item popover with account values, unknown/manual states, attention state and paid totals; Open Unifai returned to the window |
| Final companion footer | Open Unifai and Quit remained visible below the scrollable account list; both normal and fixture bundles opened their separate panels |
| Normal empty companion | “No accounts connected”, “No payments recorded” and “No payment history recorded”; no zero balance or fixture record appeared |

The final companion uses an AppKit `NSStatusItem` and `NSPopover` hosting SwiftUI. The native command and status button call the same toggle action. Automation exercised the native command because the status item itself was not exposed in its accessibility snapshot. The main window and companion share one `AppStore`.

## UI and copy review

The review applied native equivalents for labelled controls, keyboard actions, visible errors, destructive-action confirmation, empty states, locale-aware formatting and compact layouts. HTML, CSS and Playwright checks do not execute against SwiftUI. VoiceOver operation and measured color contrast are outside this receipt.

| Before | After | Why |
| --- | --- | --- |
| Balance detail labels were missing from the accessibility snapshot | Each label and amount has an explicit combined accessibility label | Preserve the meaning of purchased credit and consumption for assistive access |
| Catalogue described an older 15-minute GitHub cooldown | Catalogue, UI and client describe the implemented 30-minute cooldown | Keep setup expectations consistent with runtime behavior |
| Companion actions scrolled with the accounts | Open Unifai and Quit use a fixed footer | Keep navigation available as the account list grows |

UI copy and the new project docs received a model review using the installed Avoid AI Writing and Writing Guidelines rules. The review retained raw quotes and evidence strings. No deterministic authorship score or complete accessibility certification is claimed.

## Qualification limits

No real provider credential was supplied, discovered or read. OpenRouter and DeepSeek were exercised only with synthetic response fixtures. Live authentication, actual account scope and Hadi’s real balances remain unverified. The public GitHub smoke is the only live product API request made during verification.

Native visual checks used the current dark appearance on macOS 26.5. The macOS 14 deployment target is a compile target, not a witnessed macOS 14 runtime result. Light appearance and actual VoiceOver navigation remain unverified. This receipt does not claim distribution readiness, notarization, automatic backups, multi-process storage coordination or deferred integrations.
