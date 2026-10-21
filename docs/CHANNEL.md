# Method channel contract (Dart <-> C++)

Channel: `plugins.flutter.dev/in_app_purchase_msstore` (MethodChannel, StandardMethodCodec).
All calls are Dart -> C++ and return a map (or bool). C++ never calls Dart. Every Store call
runs off the platform thread (`co_await winrt::resume_background()`) and replies on the
platform thread. StoreContext is initialised with the top-level window handle
(IInitializeWithWindow) before any call that shows UI.

Status strings are fixed; Dart maps them to `PurchaseStatus` / errors.

| Method | Arguments | Result |
|---|---|---|
| `isAvailable` | none | `bool`: packaged process with a Store identity and a usable StoreContext |
| `queryProducts` | `{"storeIds": List<String>}` | `{"products": List<Product>, "notFound": List<String>, "error": String?}` |
| `purchase` | `{"storeId": String}` | `{"status": PurchaseStatus, "extendedError": String?, "message": String?}` |
| `reportConsumableFulfillment` | `{"storeId": String, "quantity": int, "trackingId": String}` (trackingId = a GUID string) | `{"status": FulfillmentStatus, "balanceRemaining": int?, "message": String?}` |
| `getAddOnLicenses` | none | `{"licenses": List<License>, "verifiedOnline": bool, "message": String?}` |
| `getAppLicense` | none | `{"isActive": bool, "isTrial": bool, "trialTimeRemainingSeconds": int?, "skuStoreId": String?, "expirationDate": String? (ISO-8601 UTC)}` |
| `getConsumableBalance` | `{"storeId": String}` | `{"status": FulfillmentStatus, "balanceRemaining": int?}` |

`Product` map: `{"storeId", "title", "description", "formattedPrice", "unformattedPrice" (String, as the Store gives it), "currencyCode", "productKind" ("Durable" | "Consumable" | "UnmanagedConsumable" | "Application" | other raw string), "isSubscription": bool, "subscriptionPeriod": String? ("1 Month" style, from SubscriptionInfo), "formattedRecurrencePrice": String?}`.

`License` map: `{"storeId" (product Store ID, the part before the first '/'), "skuStoreId", "inAppOfferToken", "expirationDate" (ISO-8601 UTC), "isActive": bool (raw value; Microsoft: always true for add-ons, so Dart decides ownership by expirationDate > now)}`. Durables never expire: the Store returns a far-future date.

`PurchaseStatus`: `"succeeded" | "alreadyPurchased" | "notPurchased" | "networkError" | "serverError" | "unavailable" | "unknown"`
(from `StorePurchaseStatus`; `unavailable` = not a packaged Store app or no StoreContext).

`FulfillmentStatus`: `"succeeded" | "insufficientQuantity" | "networkError" | "serverError" | "unavailable" | "unknown"`
(from `StoreConsumableStatus`).

Errors: C++ never throws across the channel for Store failures; it returns the status. A
`PlatformException` is only for bad arguments (`code: "bad_args"`).

Dart mapping (owned by the Dart worker):
- `succeeded` -> `PurchaseStatus.purchased`; `alreadyPurchased` -> `PurchaseStatus.restored`;
  `notPurchased` -> `PurchaseStatus.canceled`; the rest -> `PurchaseStatus.error` with an `IAPError`
  (`source: "msstore"`, `code` = the status string).
- `buyConsumable(autoConsume: true)` calls `reportConsumableFulfillment` with quantity 1 after
  `succeeded`, before emitting; `autoConsume: false` defers it to `completePurchase`.
- `restorePurchases` emits one `PurchaseDetails` per license whose `expirationDate` is after now,
  status `restored`.
