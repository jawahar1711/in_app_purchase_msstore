## 0.1.0

* First version. Windows implementation of `in_app_purchase` on top of
  `Windows.Services.Store.StoreContext`:
  * `isAvailable`, `queryProductDetails`, `buyNonConsumable`, `buyConsumable`,
    `completePurchase`, `restorePurchases`, `countryCode`.
  * `InAppPurchaseMsStorePlatformAddition` for Windows-only data: app licence and
    trial, add-on licences, consumable balance.
* Example app with placeholder add-on IDs and MSIX packaging.

* Recover pending consumable deliveries across restarts using a flushed journal,
  stable fulfillment GUIDs and Store reconciliation. Auto-consumed purchases now
  require `completePurchase` after app delivery; grants must deduplicate purchase IDs.
* Initiate Store purchase UI on the platform thread and return actual launch state.
* Preserve cached-license provenance and unknown expiry, expose license-read errors,
  require explicit fulfillment retry IDs, and distinguish error-bearing NotPurchased.
* Read the Windows home geographic region rather than the preferred UI locale.
