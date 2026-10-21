# in_app_purchase_msstore

Microsoft Store purchases for Flutter on Windows: a drop-in for the
[`in_app_purchase`](https://pub.dev/packages/in_app_purchase) plugin. It sells
Microsoft Store add-ons through
[`Windows.Services.Store.StoreContext`](https://learn.microsoft.com/en-us/uwp/api/windows.services.store.storecontext).

Your app keeps using `InAppPurchase.instance`. On Windows, the calls go to the Microsoft
Store. On Android, iOS and macOS, nothing changes.

Not made by Google, the Flutter team or Microsoft.

## Install

Add it next to `in_app_purchase`:

```yaml
dependencies:
  in_app_purchase: ^3.3.1
  in_app_purchase_msstore: ^0.1.0
```

No setup code is needed. The package registers itself on Windows when the app starts.

```dart
final iap = InAppPurchase.instance;
if (await iap.isAvailable()) {
  final response = await iap.queryProductDetails({'9NBLGGH4XXXX'});
  // ...
}
```

Use the add-on **Store ID** (12 characters, from Partner Center) as the product ID.

## Requirements

* Windows 10 version 1607 or later.
* The app runs as an MSIX package that is linked to an app in Partner Center.
  An unpackaged build (`flutter run`) reports `isAvailable() == false`.
* The app does not run elevated (as administrator). Microsoft does not support
  Store purchases in elevated apps.

See [example/README.md](example/README.md) for Partner Center setup, MSIX packaging
and how to test purchases.

## How the API maps to the Microsoft Store

| `in_app_purchase` | Microsoft Store |
|---|---|
| `isAvailable()` | `true` in a packaged app with a Store identity and a working `StoreContext` |
| `queryProductDetails(ids)` | `GetStoreProductsAsync`. Title, description, `FormattedPrice` as `price`, `UnformattedPrice` as `rawPrice`, `CurrencyCode`. Unknown IDs go to `notFoundIDs` |
| `buyNonConsumable()` | `RequestPurchaseAsync`. Durable add-ons and subscriptions |
| `buyConsumable(autoConsume: true)` | `RequestPurchaseAsync`, then `ReportConsumableFulfillmentAsync` (quantity 1) |
| `buyConsumable(autoConsume: false)` | `RequestPurchaseAsync`. Fulfilment waits for `completePurchase()` |
| `completePurchase()` | Acknowledges app delivery and fulfils a consumable if needed. Does nothing for durables |
| `restorePurchases()` | Add-on licences from `GetAppLicenseAsync`, emitted as `restored` |
| `countryCode()` | Windows home geographic region, not verified Store billing country |

Auto-consumption reports **quantity 1**. For Store-managed (`Consumable`) products,
this fits add-ons configured with **Quantity 1** in Partner Center. Larger packs
need the Windows addition's `getConsumableBalance` and
`reportConsumableFulfillment(quantity: ...)` to report the actual units consumed.
`autoConsume: false` only defers the shared API's quantity-1 fulfillment until
`completePurchase`; the shared API does not provide custom-quantity completion.
[Microsoft's quantity and fulfillment rules](https://learn.microsoft.com/en-us/windows/uwp/monetize/enable-consumable-add-on-purchases)
describe this distinction; [Partner Center Quantity](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/add-on/enter-app-properties)
sets how many units each Store-managed purchase grants.

Purchase results on `purchaseStream`:

| `StorePurchaseStatus` | `PurchaseStatus` |
|---|---|
| `Succeeded` | `purchased` |
| `AlreadyPurchased` | `restored` |
| `NotPurchased` without a failure HRESULT, or with `ERROR_CANCELLED` | `canceled` |
| `NotPurchased` with another failure HRESULT, `NetworkError`, `ServerError`, other | `error`, with `IAPError(source: 'msstore', code: <status>)` |

### Recovering consumable deliveries

Subscribe to `purchaseStream` at startup. Pending consumables are journaled locally
and replayed with the same `purchaseID` after a restart. Durably grant content once
per ID, then call `completePurchase` whenever `pendingCompletePurchase` is true,
**including with `autoConsume: true`**. Auto-consumption confirms Store consumption;
completion also acknowledges that your app delivered the item. A replay can arrive
after the app granted content but before it acknowledged delivery, so your grant
must be idempotent. Complete a pending delivery before buying that product again.

For Store-managed `Consumable` products, recovery only replays journal records in
`purchased`, `fulfilling` or `fulfilled` state. A remaining Store balance never
creates a delivery or proves that a pending purchase attempt was paid. For
developer-managed `UnmanagedConsumable` products, a Store collection entry can
recover one unfulfilled purchase, including an attempt with a lost reply.

If a Store-managed purchase succeeds but the app crashes before saving the
successful reply, automatic recovery cannot distinguish it from an unpaid attempt.
After a successful Store query, unresolved attempts are discarded. Covering this
window requires a backend purchase ledger: even a before/after balance change
cannot tie units to a particular purchase when other devices can buy or consume.

`restorePurchases` also retries consumable recovery after connectivity returns.
Offline recovery errors are exposed; saved deliveries and cached durable licenses
can still be emitted. Recovery uses a package-local journal and Store ownership;
it cannot recover already-consumed goods after uninstall, data deletion or on a
second device. Use one platform instance/process and keep the Store account stable
while deliveries are pending. Cross-device/account guarantees need a backend ledger.

Both buy methods return whether a Store request was actually initiated, not whether
payment succeeded. An error-bearing `NotPurchased` is an error; a result without a
failure HRESULT is treated as cancellation because the Store supplies no finer reason.

### Windows-only extras

`InAppPurchaseMsStorePlatformAddition` gives data that the shared API has no place for:
the app licence and trial, add-on licences and the balance of a consumable.
Failed/null app-license reads throw. `getOwnedAddOns` throws on read errors instead
of silently returning an unlicensed result; use `getAddOnLicenses` for cache and
error provenance. `verifiedOnline` is false if any emitted ownership is cache-only.
Unknown subscription/timed-product expiry is never synthesized as lifetime access.
For `reportConsumableFulfillment`, generate and persist a GUID before the call and
supply it as `trackingId` on every retry. Missing IDs are rejected.

```dart
final addition = InAppPurchase.instance
    .getPlatformAddition<InAppPurchaseMsStorePlatformAddition>();
```

## Verified on a real Store account

On 2026-10-21, signed test builds of the example app ran under two published apps'
identities on Windows 11, signed in with a real Microsoft Store account:

* `queryProductDetails` loaded a live durable add-on (title, description, price).
* `restorePurchases` reported an add-on the account already owned as `restored`,
  again after closing and reopening the app.
* `buyNonConsumable` opened the real Microsoft Store payment window with the
  local price including tax. The window was closed without buying.

Not yet verified on a real account: a completed purchase, consumables and
subscriptions. These paths are covered by the unit and native tests only.

## Limits

* **No pending state.** The Store dialog finishes before the call returns, so
  `PurchaseStatus.pending` is never emitted.
* **No receipts.** `Windows.Services.Store` has no client-side receipt. To check a
  purchase on your server, use the
  [Microsoft Store collection API](https://learn.microsoft.com/en-us/windows/uwp/monetize/query-for-products).
* **Add-on ownership is decided by expiry date.** Microsoft notes that
  `StoreLicense.IsActive` is always `true` for add-ons, so the plugin treats a
  licence as owned while its `ExpirationDate` is in the future.
* **No test sandbox.** Microsoft has no way to fake licence data. You test with
  a published (it can be hidden) app. See [example/README.md](example/README.md).
* **Subscriptions** are bought and restored like durables. Upgrades, downgrades and
  offer codes are not supported.

## Releases

A new version is released by pushing a tag `vX.Y.Z` that matches `version` in
`pubspec.yaml`; GitHub Actions then publishes it to pub.dev.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
