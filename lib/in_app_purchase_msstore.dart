/// Microsoft Store purchases for Flutter on Windows: a drop-in for the
/// `in_app_purchase` plugin, built on `Windows.Services.Store.StoreContext`.
/// Not made by Google, the Flutter team or Microsoft.
///
/// Add this package next to `in_app_purchase`. On Windows, Flutter calls
/// [InAppPurchaseMsStorePlatform.registerWith] at startup, so
/// `InAppPurchase.instance` talks to the Microsoft Store. Windows-only extras
/// (app licence and trial, add-on licences, consumable balance) live on
/// [InAppPurchaseMsStorePlatformAddition].
library;

export 'src/in_app_purchase_msstore_platform.dart';
export 'src/in_app_purchase_msstore_platform_addition.dart';
export 'src/types.dart';
