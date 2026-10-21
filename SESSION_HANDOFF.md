# Current state

Review fixes implemented on private `main`; do not publish or change visibility.
All nine findings from the 2026-10-21 review are accepted. Dart recovery, helper error
handling, launch status and country-code fixes are implemented; native purchase
threading, provenance, expiry, persistence and recovery are implemented.

Verification: initial regression run failed 14 Dart tests and 3 native tests before
fixes. The expanded Dart suite passes 81 tests. All 21 native tests and the Windows debug example build pass, including the
stronger journal and suspended-reply checks. Format and analysis are clean.
Final CI URL belongs in `docs/SUMMARY.md` after hosted CI completes.

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
