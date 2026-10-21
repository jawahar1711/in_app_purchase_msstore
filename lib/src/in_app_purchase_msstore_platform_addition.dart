import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'channel.dart';
import 'types.dart';

/// Windows-only calls that the common `in_app_purchase` API has no place for.
///
/// Get it with
/// `InAppPurchase.instance.getPlatformAddition<InAppPurchaseMsStorePlatformAddition>()`.
class InAppPurchaseMsStorePlatformAddition
    extends InAppPurchasePlatformAddition {
  /// Creates the addition. [channel] and [clock] are for tests.
  InAppPurchaseMsStorePlatformAddition({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting DateTime Function()? clock,
  }) : _channel = channel ?? msStoreChannel,
       _clock = clock ?? systemClock;

  final MethodChannel _channel;
  final DateTime Function() _clock;

  /// The licence of the app itself, including the trial state.
  Future<MsStoreAppLicense> getAppLicense() async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('getAppLicense');
    _checkRead(map, 'getAppLicense');
    return MsStoreAppLicense.fromChannel(map!);
  }

  /// Every add-on licence of the signed-in user, expired ones included.
  ///
  /// Use [MsStoreAddOnLicense.isOwnedAt] to decide ownership.
  Future<MsStoreAddOnLicenses> getAddOnLicenses() async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('getAddOnLicenses');
    if (map == null) _checkRead(map, 'getAddOnLicenses');
    return MsStoreAddOnLicenses.fromChannel(map!);
  }

  /// The add-on licences that have not expired now.
  Future<List<MsStoreAddOnLicense>> getOwnedAddOns() async {
    final DateTime now = _clock();
    final result = await getAddOnLicenses();
    if (result.message != null) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: 'getOwnedAddOns',
        message: result.message,
      );
    }
    return result.licenses
        .where((MsStoreAddOnLicense l) => l.isOwnedAt(now))
        .toList();
  }

  /// The units left of the Store-managed consumable [storeId].
  Future<MsStoreFulfillmentResult> getConsumableBalance(String storeId) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>(
          'getConsumableBalance',
          <String, Object?>{'storeId': storeId},
        );
    return MsStoreFulfillmentResult.fromChannel(map);
  }

  void _checkRead(Map<Object?, Object?>? map, String method) {
    if (map == null || map['message'] != null) {
      throw InAppPurchaseException(
        source: msStoreSource,
        code: method,
        message: map?['message'] as String? ?? 'No result from the platform.',
      );
    }
  }

  /// Reports [quantity] units of the consumable [storeId] as used.
  ///
  /// Persist and pass the same [trackingId] on every retry. Missing or invalid
  /// GUIDs throw before dispatch; the helper never creates a hidden retry ID.
  Future<MsStoreFulfillmentResult> reportConsumableFulfillment(
    String storeId, {
    int quantity = 1,
    String? trackingId,
  }) async {
    if (trackingId == null ||
        !RegExp(
          r'^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$',
        ).hasMatch(trackingId)) {
      throw ArgumentError.value(
        trackingId,
        'trackingId',
        'A persisted GUID is required.',
      );
    }
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>(
          'reportConsumableFulfillment',
          <String, Object?>{
            'storeId': storeId,
            'quantity': quantity,
            'trackingId': trackingId,
          },
        );
    return MsStoreFulfillmentResult.fromChannel(map);
  }
}
