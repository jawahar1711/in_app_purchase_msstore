# in_app_purchase_msstore

Unofficial Windows implementation of Flutter's `in_app_purchase` interface, using
Microsoft Store `StoreContext` for products, purchases, consumables and restore.
Windows extras expose app/trial licenses, add-on provenance and consumable balances.
BSD-3-Clause. Repository remains private; nothing has been published to pub.dev.

## Verification (2026-10-21)

- 81 Dart tests pass; format and `flutter analyze` pass with no issues.
- 21 C++ tests pass on Windows, including the real coroutine with an injected Store
  adapter, asynchronous UI reply dispatch, and atomic journal failure handling.
- Windows debug example build passes. GitHub-hosted Ubuntu/Windows CI: pending push.
- Test-first evidence: 14 new Dart regressions and 3 native regressions failed before
  their fixes. Additional recovery edges and native persistence/COM tests were added;
  the latter caught missing-file handling and CO_E_NOTINITIALIZED before correction.

## Review disposition

All nine findings accepted and fixed; none disputed. No independent post-fix review
or packaged commerce verification is claimed.

| # | Finding and fix | Regression evidence |
|---|---|---|
| 1 | Unfinished consumables: persisted attempts, delivery/fulfillment states, stable GUIDs, startup replay and Store reconciliation; app acknowledges even auto-consumed deliveries | `review_regressions_test.dart`: restart in both modes, lost purchase/fulfillment responses, failed journal write, Store-only units, same-session retry; native journal test |
| 2 | Purchase context/HWND/request initiation on UI thread; MTA lifetime retained for pool work and replies | Native injected adapter asserts initiating thread/HWND and reply thread across suspension |
| 3 | Cached-only entries prevent aggregate online confirmation; matching online data replaces cached metadata | Native cached A / online empty regression |
| 4 | Missing/nonpositive expiry never becomes lifetime ownership; Store-supplied far-future dates still work | Native unknown-expiry and year-9999 regressions |
| 5 | Fulfillment helper rejects missing retry GUIDs before dispatch | Dart missing-ID and lost-response/same-ID regressions |
| 6 | Failed/null app license and list-only ownership reads throw | Dart failed/null/inactive and partial ownership regressions |
| 7 | Buy boolean reflects request initiation, including unavailable/preflight paths | Both Dart buy methods; native asynchronous failure retains started=true |
| 8 | NotPurchased with failing HRESULT exposes IAPError, except known cancellation | Dart failure/dismissal regression |
| 9 | Country fallback reads actual Windows home geographic region | Dart channel returns AU independently of UI locale |

## Limits and founder steps

Delivery notifications are at least once. Apps must durably deduplicate grants by
`purchaseID` before `completePurchase`. Use one plugin instance/process and keep the
Store account stable while deliveries are pending. Local recovery cannot reconstruct
consumed goods after uninstall or on another device. No client receipts, subscription
upgrade/downgrade, or verified Store billing-country API. See [CHANNEL.md](CHANNEL.md).

Founder needed: a Partner Center test app with durable and consumable add-ons for a
packaged, non-elevated buy/unlock/relaunch/restore check. Unit tests and hosted builds
do not prove commerce. Public GitHub visibility, pub.dev publishing and publisher
choice still require founder approval. No Store account/app changes were made.
