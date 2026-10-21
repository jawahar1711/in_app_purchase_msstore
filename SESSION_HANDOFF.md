# Current state

Review fixes implemented on private `main`; do not publish or change visibility.
All nine findings from the 2026-10-21 review are accepted. Dart recovery, helper error
handling, launch status and country-code fixes are implemented; native purchase
threading, provenance, expiry, persistence and recovery are implemented.

Implementation commit: `a6c0ca3`. Initial regression run failed 14 Dart tests and
3 native tests before fixes. Final validation: 81 Dart + 21 native tests, clean
format/analysis, and Windows debug/release example builds. Hosted CI is green:
https://github.com/jawahar1711/in_app_purchase_msstore/actions/runs/39572890018
The review disposition and delivery limits are in `docs/SUMMARY.md`.
Remaining work is external: packaged commerce proof and the Herdr notification
blocker below. Do not publish or create a Store test app without founder approval.

## Recovery contract

2026-10-21: retain a journal until app delivery acknowledgment, even after automatic
Store consumption. Persist the GUID before calling the Store and reuse it after an
ambiguous response. Why: Store-only recovery cannot recover already-consumed units,
and a new GUID on retry can consume another unit. Application grants must deduplicate
`purchaseID`; notification and app database delivery cannot be one atomic transaction.

## Native file handles

2026-10-21: compare CreateFileW results explicitly with INVALID_HANDLE_VALUE before
wrapping them in winrt::handle. Why: winrt::handle's null sentinel does not identify
CreateFileW's -1 sentinel, so a missing journal becomes an invalid-handle exception.

## Remaining external proof

Packaged, non-elevated buy/unlock/relaunch/restore needs a Partner Center test app with
one durable and one consumable. Unit tests/builds do not prove real commerce. No
Store app/account or publication changes are authorized. Herdr reporting is blocked
in this process because HERDR_ENV is absent; do not spoof it or control another session.

## COM lifetime across suspension

2026-10-21: hold a CoIncrementMTAUsage cookie for each native async operation until
its reply completes. Why: Flutter's UI apartment is STA; resume_background alone
does not initialize thread-pool COM. The suspended adapter regression reproduced
CO_E_NOTINITIALIZED (0x800401F0) on await continuation and reply marshaling without
an MTA lifetime. Initiate purchase UI on STA and keep non-UI work on the pool.
