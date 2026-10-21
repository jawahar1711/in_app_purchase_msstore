## 0.1.0 (unreleased)

* First version. Windows implementation of `in_app_purchase` on top of
  `Windows.Services.Store.StoreContext`:
  * `isAvailable`, `queryProductDetails`, `buyNonConsumable`, `buyConsumable`,
    `completePurchase`, `restorePurchases`, `countryCode`.
  * `InAppPurchaseMsStorePlatformAddition` for Windows-only data: app licence and
    trial, add-on licences, consumable balance.
* Example app with placeholder add-on IDs and MSIX packaging.
