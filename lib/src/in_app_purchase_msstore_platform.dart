import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'channel.dart';
import 'in_app_purchase_msstore_platform_addition.dart';
import 'types.dart';

/// The Microsoft Store implementation of [InAppPurchasePlatform].
///
/// Windows has no "pending" purchase: the Store dialog returns only when the
/// purchase is done, canceled or failed, so [PurchaseStatus.pending] is never
/// emitted.
class InAppPurchaseMsStorePlatform extends InAppPurchasePlatform {
  /// Creates the platform. [channel] and [clock] are for tests.
  InAppPurchaseMsStorePlatform({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting DateTime Function()? clock,
  }) : _channel = channel ?? msStoreChannel,
       _clock = clock ?? systemClock;

  final MethodChannel _channel;
  final DateTime Function() _clock;
  final StreamController<List<PurchaseDetails>> _purchases =
      StreamController<List<PurchaseDetails>>.broadcast();

  /// Registers this class as the `in_app_purchase` platform on Windows.
  static void registerWith() {
    InAppPurchasePlatform.instance = InAppPurchaseMsStorePlatform();
    InAppPurchasePlatformAddition.instance =
        InAppPurchaseMsStorePlatformAddition();
  }

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _purchases.stream;

  /// True in a packaged (MSIX) app with a Store identity and a StoreContext.
  @override
  Future<bool> isAvailable() async =>
      await _channel.invokeMethod<bool>('isAvailable') ?? false;

  /// Reads the products with `StoreContext.GetStoreProductsAsync`.
  ///
  /// [identifiers] are Store IDs (the 12-character IDs from Partner Center).
  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('queryProducts', <String, Object?>{
          'storeIds': identifiers.toList(),
        });
    final String? error = map?['error'] as String?;
    if (map == null || error != null) {
      return ProductDetailsResponse(
        productDetails: const <ProductDetails>[],
        notFoundIDs: identifiers.toList(),
        error: IAPError(
          source: msStoreSource,
          code: 'queryProducts',
          message: error ?? 'No result from the platform.',
        ),
      );
    }
    return ProductDetailsResponse(
      productDetails: <ProductDetails>[
        for (final Object? item in map['products'] as List<Object?>? ?? [])
          if (item is Map<Object?, Object?>)
            MsStoreProductDetails.fromChannel(item),
      ],
      notFoundIDs: <String>[
        for (final Object? id in map['notFound'] as List<Object?>? ?? [])
          if (id is String) id,
      ],
    );
  }

  /// Buys a durable or subscription add-on with `RequestPurchaseAsync`.
  ///
  /// Returns true once the Store dialog has closed; the result arrives on
  /// [purchaseStream].
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    final MsStorePurchaseDetails purchase = await _purchase(
      purchaseParam.productDetails.id,
      isConsumable: false,
    );
    _purchases.add(<PurchaseDetails>[purchase]);
    return true;
  }

  /// Buys a consumable add-on with `RequestPurchaseAsync`.
  ///
  /// With [autoConsume], one unit is reported as fulfilled before the result
  /// is emitted. If that report fails, or [autoConsume] is false, the result
  /// has `pendingCompletePurchase` set: call [completePurchase] to fulfil it.
  /// The Store refuses to sell a consumable again until it is fulfilled.
  @override
  Future<bool> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) async {
    final MsStorePurchaseDetails purchase = await _purchase(
      purchaseParam.productDetails.id,
      isConsumable: true,
    );
    if (purchase.status == PurchaseStatus.purchased ||
        purchase.status == PurchaseStatus.restored) {
      purchase.pendingCompletePurchase = true;
    }
    if (autoConsume && purchase.status == PurchaseStatus.purchased) {
      final MsStoreFulfillmentResult result = await _fulfill(purchase);
      if (result.status == MsStoreFulfillmentStatus.succeeded) {
        purchase.pendingCompletePurchase = false;
      }
    }
    _purchases.add(<PurchaseDetails>[purchase]);
    return true;
  }

  /// Fulfils a consumable that is not yet fulfilled. Does nothing for other
  /// purchases: the Store has no acknowledge step.
  ///
  /// Throws an [InAppPurchaseException] when the Store refuses the
  /// fulfilment; the purchase stays pending so the call can be retried.
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    if (purchase is! MsStorePurchaseDetails ||
        !purchase.isConsumable ||
        !purchase.pendingCompletePurchase) {
      return;
    }
    final MsStoreFulfillmentResult result = await _fulfill(purchase);
    if (result.status != MsStoreFulfillmentStatus.succeeded) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: result.status.name,
        message: result.message,
      );
    }
    purchase.pendingCompletePurchase = false;
  }

  /// Emits one [PurchaseStatus.restored] result for each add-on licence that
  /// has not expired, in a single list (empty when nothing is owned).
  ///
  /// Microsoft documents `StoreLicense.IsActive` as always true for add-ons,
  /// so ownership is judged by the expiry date. Consumables have no licence
  /// and are never restored. Throws an [InAppPurchaseException] when the
  /// Store could not be read. [applicationUserName] is not used.
  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('getAddOnLicenses');
    if (map == null) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: 'restore',
        message: 'No result from the platform.',
      );
    }
    final MsStoreAddOnLicenses result = MsStoreAddOnLicenses.fromChannel(map);
    if (result.licenses.isEmpty && result.message != null) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: 'restore',
        message: result.message,
      );
    }
    final DateTime now = _clock();
    _purchases.add(<PurchaseDetails>[
      for (final MsStoreAddOnLicense license in result.licenses)
        if (license.isOwnedAt(now))
          MsStorePurchaseDetails(
            productID: license.storeId,
            transactionDate: null,
            status: PurchaseStatus.restored,
            skuStoreId: license.skuStoreId,
            inAppOfferToken: license.inAppOfferToken,
            expirationDate: license.expirationDate,
          ),
    ]);
  }

  /// The Store has no country API, so this returns the country of the
  /// device locale (ISO 3166-1 alpha-2), or an empty string.
  @override
  Future<String> countryCode() async =>
      PlatformDispatcher.instance.locale.countryCode ?? '';

  Future<MsStorePurchaseDetails> _purchase(
    String storeId, {
    required bool isConsumable,
  }) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('purchase', <String, Object?>{
          'storeId': storeId,
        });
    final String code = map?['status'] as String? ?? 'unknown';
    final PurchaseStatus status = _statusFor(code);
    final MsStorePurchaseDetails purchase = MsStorePurchaseDetails(
      purchaseID: isConsumable ? newTrackingId() : null,
      productID: storeId,
      transactionDate: '${_clock().millisecondsSinceEpoch}',
      status: status,
      isConsumable: isConsumable,
      extendedError: map?['extendedError'] as String?,
    );
    if (status == PurchaseStatus.error) {
      purchase.error = IAPError(
        source: msStoreSource,
        code: code,
        message: map?['message'] as String? ?? code,
        details: purchase.extendedError,
      );
    }
    return purchase;
  }

  Future<MsStoreFulfillmentResult> _fulfill(
    MsStorePurchaseDetails purchase,
  ) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>(
          'reportConsumableFulfillment',
          <String, Object?>{
            'storeId': purchase.productID,
            'quantity': 1,
            'trackingId': purchase.purchaseID ?? newTrackingId(),
          },
        );
    return MsStoreFulfillmentResult.fromChannel(map);
  }

  static PurchaseStatus _statusFor(String code) {
    switch (code) {
      case 'succeeded':
        return PurchaseStatus.purchased;
      case 'alreadyPurchased':
        return PurchaseStatus.restored;
      case 'notPurchased':
        return PurchaseStatus.canceled;
      default:
        return PurchaseStatus.error;
    }
  }
}
