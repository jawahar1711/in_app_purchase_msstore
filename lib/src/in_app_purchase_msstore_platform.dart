import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'channel.dart';
import 'in_app_purchase_msstore_platform_addition.dart';
import 'types.dart';
import 'purchase_journal.dart';

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
       _clock = clock ?? systemClock {
    _journal = PurchaseJournal(_channel);
    _purchases = StreamController<List<PurchaseDetails>>.broadcast(
      onListen: () {
        if (_recoveryStarted) return;
        _recoveryStarted = true;
        unawaited(
          _serial(_recover).catchError((Object error, StackTrace stack) {
            _purchases.addError(error, stack);
          }),
        );
      },
    );
  }

  final MethodChannel _channel;
  final DateTime Function() _clock;
  late final StreamController<List<PurchaseDetails>> _purchases;
  late final PurchaseJournal _journal;
  bool _recoveryStarted = false;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

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
  /// Returns whether a Store request was initiated; the final purchase
  /// result arrives on [purchaseStream].
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    final MsStorePurchaseDetails purchase = await _purchase(
      purchaseParam.productDetails.id,
      isConsumable: false,
    );
    _purchases.add(<PurchaseDetails>[purchase]);
    return purchase.requestStarted;
  }

  /// Buys a consumable, journaling the attempt before opening the Store.
  /// Auto-consumption does not acknowledge delivery: after durably granting
  /// the item, always call [completePurchase], including with [autoConsume].
  @override
  Future<bool> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) => _serial(() async {
    final storeId = purchaseParam.productDetails.id;
    if (!await isAvailable()) {
      final purchase =
          MsStorePurchaseDetails(
              productID: storeId,
              transactionDate: null,
              status: PurchaseStatus.error,
              isConsumable: true,
            )
            ..error = IAPError(
              source: msStoreSource,
              code: 'unavailable',
              message: 'The Microsoft Store is unavailable.',
            );
      _purchases.add([purchase]);
      return false;
    }
    final previous = (await _journal.read()).where(
      (r) => r['storeId'] == storeId,
    );
    if (previous.isNotEmpty) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: 'pending_delivery',
        message:
            'Complete the previous delivery before buying this product again.',
      );
    }
    final record = <String, Object?>{
      'id': newTrackingId(),
      'storeId': storeId,
      'state': 'attempt',
      'date': '${_clock().millisecondsSinceEpoch}',
    };
    await _journal.put(record);
    final purchase = await _purchase(
      storeId,
      isConsumable: true,
      trackingId: record['id']! as String,
    );
    if (purchase.status == PurchaseStatus.purchased ||
        purchase.status == PurchaseStatus.restored) {
      record['state'] = 'purchased';
      await _journal.put(record);
      purchase.pendingCompletePurchase = true;
      if (autoConsume && purchase.status == PurchaseStatus.purchased) {
        await _consume(record, purchase);
      }
    } else if (!purchase.requestStarted ||
        purchase.status == PurchaseStatus.canceled ||
        purchase.error?.code == 'notPurchased') {
      await _journal.remove(purchase.purchaseID!);
    }
    _purchases.add(<PurchaseDetails>[purchase]);
    return purchase.requestStarted;
  });

  /// Acknowledges durable application delivery and fulfils the consumable
  /// if necessary. Repeated/overlapping calls reuse the persisted GUID.
  @override
  Future<void> completePurchase(PurchaseDetails purchase) => _serial(() async {
    if (purchase is! MsStorePurchaseDetails ||
        !purchase.isConsumable ||
        !purchase.pendingCompletePurchase) {
      return;
    }
    final records = (await _journal.read()).where(
      (r) => r['id'] == purchase.purchaseID,
    );
    if (records.isEmpty) {
      purchase.pendingCompletePurchase = false;
      return;
    }
    final record = Map<String, Object?>.of(records.single);
    if (record['state'] != 'fulfilled') {
      final result = await _consume(record, purchase);
      if (result.status != MsStoreFulfillmentStatus.succeeded) {
        throw InAppPurchaseException(
          source: msStoreSource,
          code: result.status.name,
          message: result.message,
        );
      }
    }
    await _journal.remove(purchase.purchaseID!);
    purchase.pendingCompletePurchase = false;
  });

  Future<MsStoreFulfillmentResult> _consume(
    Map<String, Object?> record,
    MsStorePurchaseDetails purchase,
  ) async {
    record['state'] = 'fulfilling';
    await _journal.put(record);
    final result = await _fulfill(purchase);
    if (result.status == MsStoreFulfillmentStatus.succeeded) {
      record['state'] = 'fulfilled';
      await _journal.put(record);
    }
    return result;
  }

  Future<void> _recover() async {
    final records = await _journal.read();
    Map<Object?, Object?>? ownership;
    Object? failure;
    try {
      ownership = await _channel.invokeMapMethod<Object?, Object?>(
        'getPendingConsumables',
      );
      if (ownership == null || ownership['message'] != null) {
        throw InAppPurchaseException(
          source: msStoreSource,
          code: 'recovery',
          message: ownership?['message'] as String? ?? 'No recovery result.',
        );
      }
    } catch (error) {
      failure = error;
    }
    final recovered = [for (final r in records) Map<String, Object?>.of(r)];
    if (failure == null) {
      for (final item in ownership!['purchases'] as List<Object?>? ?? []) {
        final owned = item! as Map<Object?, Object?>;
        final id = owned['storeId']! as String;
        final quantity = owned['quantity']! as int;
        if (quantity <= 0) continue;
        final existing = recovered.where((r) => r['storeId'] == id).toList();
        if (existing.isNotEmpty) {
          // An ambiguous fulfilment may already have reduced the balance.
          // Never invent another GUID while this product has a local record.
          for (final record in existing) {
            if (record['state'] == 'attempt') record['state'] = 'purchased';
          }
        } else {
          for (var unit = 0; unit < quantity; unit++) {
            recovered.add({
              'id': newTrackingId(),
              'storeId': id,
              'state': 'purchased',
              'date': null,
            });
          }
        }
      }
      // Attempts which never reached fulfillment can be dropped after a
      // successful empty ownership check. No Store retry GUID has been used.
      recovered.removeWhere((record) => record['state'] == 'attempt');
      if (records.isNotEmpty || recovered.isNotEmpty) {
        await _journal.save(recovered);
      }
    }
    final deliveries = <PurchaseDetails>[
      for (final record in recovered)
        if (record['state'] != 'attempt')
          MsStorePurchaseDetails(
            purchaseID: record['id']! as String,
            productID: record['storeId']! as String,
            transactionDate: record['date'] as String?,
            status: PurchaseStatus.purchased,
            isConsumable: true,
          )..pendingCompletePurchase = true,
    ];
    if (deliveries.isNotEmpty) _purchases.add(deliveries);
    if (failure != null) throw failure;
  }

  /// Emits one [PurchaseStatus.restored] result for each add-on licence that
  /// has not expired, in a single list (empty when nothing is owned).
  ///
  /// Microsoft documents `StoreLicense.IsActive` as always true for add-ons,
  /// so ownership is judged by the expiry date. Also retries consumable
  /// recovery, emitting pending deliveries separately. Throws an [InAppPurchaseException] when the
  /// Store could not be read. [applicationUserName] is not used.
  @override
  Future<void> restorePurchases({String? applicationUserName}) => _serial(
    () async {
      Object? recoveryError;
      try {
        await _recover();
      } catch (error) {
        recoveryError = error;
      }
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
      if (recoveryError != null) throw recoveryError;
    },
  );

  /// The Store has no country API, so this returns the country of the
  /// Windows home geographic region (not Store billing country), or an empty string.
  @override
  Future<String> countryCode() async =>
      await _channel.invokeMethod<String>('countryCode') ?? '';

  Future<MsStorePurchaseDetails> _purchase(
    String storeId, {
    required bool isConsumable,
    String? trackingId,
  }) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('purchase', <String, Object?>{
          'storeId': storeId,
        });
    final String code = map?['status'] as String? ?? 'unknown';
    final error = map?['extendedError'] as String?;
    final hresult = error == null
        ? 0
        : int.tryParse(error.replaceFirst(RegExp(r'^0[xX]'), ''), radix: 16) ??
              -1;
    final PurchaseStatus status =
        code == 'notPurchased' && hresult != 0 && hresult != 0x800704C7
        ? PurchaseStatus.error
        : _statusFor(code);
    final MsStorePurchaseDetails purchase = MsStorePurchaseDetails(
      purchaseID: isConsumable ? trackingId : null,
      requestStarted: map?['requestStarted'] as bool? ?? false,
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
            'trackingId': purchase.purchaseID!,
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
