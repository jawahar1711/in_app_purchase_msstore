# in_app_purchase_msstore: project status

Microsoft Store purchases for Flutter on Windows: a drop-in for the `in_app_purchase`
interface (not made by Google, the Flutter team or Microsoft), using
Microsoft Store `StoreContext` for products, purchases, consumables and restore.
Windows extras expose app/trial licenses, add-on provenance and consumable balances.
Licence: BSD-3-Clause.

## Verification (2026-10-21)

- 83 Dart tests pass; format and `flutter analyze` pass with no issues.
- 21 C++ tests pass on Windows, including the real coroutine with an injected Store
  adapter, asynchronous UI reply dispatch, and atomic journal failure handling.
- Windows debug and release example builds pass.
- GitHub-hosted Ubuntu and Windows CI runs on every push (`.github/workflows/ci.yml`).
- Real Store account (2026-10-21, Windows 11, test builds under two published apps'
  identities): product query, restore of an owned durable (also after relaunch) and
  the real payment window (closed without buying) all worked.
- Not yet verified on a real account: a completed purchase, consumables, subscriptions.

## Hardening notes

| Area | Behaviour | Regression evidence |
|---|---|---|
| Unfinished consumables | Stable GUIDs and startup replay of saved deliveries; only developer-managed collection entries recover purchases without a confirmed journal record | `review_regressions_test.dart`: restart in both modes, lost unmanaged purchase/fulfillment responses, failed journal write, Store-managed balance/attempt rejection, mixed collection, same-session retry; native journal test |
| Threading | Purchase context, window handle and request start on the UI thread; other Store work on the thread pool with replies back on the platform thread | Native injected adapter asserts initiating thread/HWND and reply thread across suspension |
| Cached licenses | Cached-only entries never count as confirmed online; matching online data replaces cached metadata | Native cached / online-empty regression |
| Unknown expiry | A missing or non-positive expiry never becomes lifetime ownership; Store-supplied far-future dates still work | Native unknown-expiry and year-9999 regressions |
| Fulfillment retries | The fulfillment helper rejects a missing retry GUID before dispatch | Dart missing-ID and lost-response/same-ID regressions |
| License reads | Failed or null app-license and list-only ownership reads throw | Dart failed/null/inactive and partial ownership regressions |
| Buy return value | `buy*` returns whether a Store request actually started | Both Dart buy methods; native asynchronous failure keeps started=true |
| Cancel vs error | `NotPurchased` with a failing HRESULT is an error, except a known cancellation | Dart failure/dismissal regression |
| Country | `countryCode` reads the Windows home geographic region (not a Store billing country) | Dart channel test independent of UI locale |

## Limits

Delivery notifications are at least once. Apps must durably deduplicate grants by
`purchaseID` before `completePurchase`. Use one plugin instance/process and keep the
Store account stable while deliveries are pending. Local recovery cannot reconstruct
consumed goods after uninstall or on another device. No client receipts, subscription
upgrade/downgrade, or verified Store billing-country API. See [CHANNEL.md](CHANNEL.md).

Store-managed balances never prove an undelivered purchase. A crash before the
successful purchase reply is journaled requires a backend ledger for recovery.
Shared-API fulfillment reports quantity 1; larger Store-managed packs require
explicit quantity handling through the Windows addition.
