# Method channel contract (Dart <-> C++)

Channel: `plugins.flutter.dev/in_app_purchase_msstore`, StandardMethodCodec.
Purchase context creation, HWND binding and `RequestPurchaseAsync` initiation run on
the Flutter platform/UI thread. Awaiting the operation does not block that thread.
Other Store calls run on the thread pool; replies return to the platform apartment.
Each coroutine holds an MTA usage cookie so background continuations have COM
initialized even when the application only initialized its UI STA.

| Method | Arguments | Result |
|---|---|---|
| `isAvailable` | none | bool: packaged process and usable StoreContext |
| `queryProducts` | `{storeIds: List<String>}` | `{products: List<Product>, notFound: List<String>, error: String?}` |
| `purchase` | `{storeId: String}` | `{status: PurchaseStatus, requestStarted: bool, extendedError: String?, message: String?}` |
| `reportConsumableFulfillment` | `{storeId: String, quantity: int, trackingId: GUID String}` | `{status: FulfillmentStatus, balanceRemaining: int?, message: String?}` |
| `getAddOnLicenses` | none | `{licenses: List<License>, verifiedOnline: bool, message: String?}` |
| `getAppLicense` | none | `{isActive: bool, isTrial: bool, trialTimeRemainingSeconds: int?, skuStoreId: String?, expirationDate: String?, message: String?}` |
| `getConsumableBalance` | `{storeId: String}` | `{status: FulfillmentStatus, balanceRemaining: int?, message: String?}` |
| `countryCode` | none | Windows `GlobalizationPreferences.HomeGeographicRegion`, or empty string; not Store billing country |
| `getPendingConsumables` | none | `{purchases: [{storeId: String, productKind: String, quantity: int}], message: String?}`; online collection plus Store-managed balances |
| `readPurchaseJournal` | none | JSON text; missing file returns `[]` |
| `writePurchaseJournal` | JSON text | true only after flushed atomic replacement; I/O errors are `PlatformException(journal_io)` |

`Product`: `{storeId, title, description, formattedPrice, unformattedPrice: String,
currencyCode, productKind, isSubscription: bool, subscriptionPeriod: String?,
formattedRecurrencePrice: String?}`. Product kinds include `Durable`, `Consumable`
(Store-managed) and `UnmanagedConsumable` (developer-managed).

For `getPendingConsumables`, `Consumable.quantity` is the remaining Store balance,
not a count of undelivered purchases. `UnmanagedConsumable.quantity` is 1 for one
unfulfilled purchase. Dart only reconciles collection entries explicitly marked
`UnmanagedConsumable`; missing or unknown product kinds cannot prove a purchase.

`License`: `{storeId, skuStoreId, inAppOfferToken, expirationDate: ISO-8601 UTC,
isActive: bool}`. Add-on `IsActive` is not ownership evidence. Dart requires a future
expiry. Collection entries without a positive owned-SKU end date are incomplete,
not lifetime licenses. Perpetual ownership requires a Store-supplied far-future date.
A complete online collection replaces matching cached entries. Cached-only entries
remain available, but make aggregate `verifiedOnline` false. A partial online read
keeps the cache, sets `verifiedOnline: false`, and includes a message.

Purchase statuses: `succeeded`, `alreadyPurchased`, `notPurchased`, `networkError`,
`serverError`, `unavailable`, `unknown`. `requestStarted` becomes true only after the
Store returns an async purchase operation, even if that operation later fails.
`notPurchased` with a failing HRESULT is an error except `ERROR_CANCELLED`
(`0x800704C7`); no HRESULT is treated as cancellation, with no claim that the Store
proved user dismissal. Diagnostics remain on the purchase.

Fulfillment statuses: `succeeded`, `insufficientQuantity`, `networkError`,
`serverError`, `unavailable`, `unknown`. Store failures return status/message maps;
bad arguments and journal I/O failures use channel exceptions. Dart license helpers
throw on null/failed reads. The detailed add-on wrapper preserves partial results;
the list-only helper throws when there is a failure message.

## Recovery and delivery

The singleton Dart platform serializes journal mutations and consumable operations.
Native persistence is a package-local `in_app_purchase_msstore/pending.json` file,
written to a sibling temporary file, flushed, then replaced with `MoveFileExW`.
Journal records contain `{id: GUID, storeId, state, date}`. States are `attempt`
(before purchase dispatch), `purchased`, `fulfilling` (before consumption dispatch),
and `fulfilled` (Store confirmation received). The same GUID is used for every
fulfillment retry. Corrupt/unreadable state fails rather than discarding purchases.

On the first stream subscription, recovery replays saved `purchased`, `fulfilling`
and `fulfilled` records. Only `UnmanagedConsumable` collection entries can promote
an `attempt` or create a record, one per outstanding purchase with its saved GUID
reused when present. A Store-managed `Consumable` balance never creates records or
promotes an attempt, regardless of its quantity. A successful query discards
unresolved attempts. A failed query leaves records intact. Local
`purchased`/`fulfilling`/`fulfilled` records can still replay offline.
`restorePurchases` retries recovery in the same session, then emits durable licenses.
An offline recovery error is exposed even when cached deliveries/licenses are emitted.

Store consumption and app delivery acknowledgment are distinct. Auto-consumption
still leaves `pendingCompletePurchase: true`. The app durably grants content,
deduplicating by `purchaseID`, then calls `completePurchase`. That call consumes only
if needed and removes the journal record after confirmed fulfillment. A crash after
consumption or after app delivery replays the same ID; the app must make delivery
idempotent. This is at-least-once notification, not an atomic transaction with the
app's database. Another purchase of the same product is rejected until its pending
delivery is completed.

Both auto-consumption and `completePurchase` report **quantity 1**, so the shared
API fits Store-managed products configured with **Quantity 1** in Partner Center.
Larger Store-managed packs must use the Windows addition's `getConsumableBalance`
and `reportConsumableFulfillment` with the actual consumed quantity and a persisted
retry GUID. `autoConsume: false` only delays the shared API's quantity-1 call;
the shared API does not provide custom-quantity completion for larger packs.

A Store-managed purchase that succeeds before a crash but whose successful reply
was never journaled remains ambiguous. Covering that window needs a backend
purchase ledger. The plugin deliberately does not infer payment from a balance
delta: other devices can buy or consume units, so a changed balance cannot identify
the attempted purchase. The plugin provides no automatic delivery for that window.

Use one platform instance/isolate/process for a package and the same Store account
while deliveries are pending. Local recovery does not survive uninstall/data deletion,
and cannot reconstruct already-consumed units on another device. Applications needing
cross-device/account delivery guarantees need an account-bound backend ledger.

Contract sources: [Flutter purchase stream](https://pub.dev/documentation/in_app_purchase_platform_interface/latest/in_app_purchase_platform_interface/InAppPurchasePlatform/purchaseStream.html),
[Microsoft UI-thread requirement](https://learn.microsoft.com/en-us/uwp/api/windows.services.store.storecontext.requestpurchaseasync),
[fulfillment GUID retries](https://learn.microsoft.com/en-us/uwp/api/windows.services.store.storecontext.reportconsumablefulfillmentasync),
[consumable types](https://learn.microsoft.com/en-us/uwp/api/windows.services.store.storeproduct.productkind),
[Partner Center quantity](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/add-on/enter-app-properties),
[consumable fulfillment](https://learn.microsoft.com/en-us/windows/uwp/monetize/enable-consumable-add-on-purchases).
