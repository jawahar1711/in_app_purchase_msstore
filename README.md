# in_app_purchase_msstore

**Unofficial** Windows implementation of Flutter's
[`in_app_purchase`](https://pub.dev/packages/in_app_purchase) plugin. It sells
Microsoft Store add-ons through
[`Windows.Services.Store.StoreContext`](https://learn.microsoft.com/en-us/uwp/api/windows.services.store.storecontext).

Your app keeps using `InAppPurchase.instance`. On Windows, the calls go to the Microsoft
Store. On Android, iOS and macOS, nothing changes.

This package is not made or endorsed by the Flutter team or by Microsoft.

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
| `completePurchase()` | Fulfils a consumable that was not auto-consumed. Does nothing for durables: the Store has no acknowledge step |
| `restorePurchases()` | Add-on licences from `GetAppLicenseAsync`, emitted as `restored` |
| `countryCode()` | The Store has no API for this. Returns the device's home region |

Purchase results on `purchaseStream`:

| `StorePurchaseStatus` | `PurchaseStatus` |
|---|---|
| `Succeeded` | `purchased` |
| `AlreadyPurchased` | `restored` |
| `NotPurchased` (user closed the dialog) | `canceled` |
| `NetworkError`, `ServerError`, other | `error`, with `IAPError(source: 'msstore', code: <status>)` |

### Windows-only extras

`InAppPurchaseMsStorePlatformAddition` gives data that the shared API has no place for:
the app licence and trial, add-on licences and the balance of a consumable.

```dart
final addition = InAppPurchase.instance
    .getPlatformAddition<InAppPurchaseMsStorePlatformAddition>();
```

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

## License

BSD-3-Clause. See [LICENSE](LICENSE).
