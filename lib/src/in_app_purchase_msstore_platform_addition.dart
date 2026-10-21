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
    return MsStoreAppLicense.fromChannel(map ?? const <Object?, Object?>{});
  }

  /// Every add-on licence of the signed-in user, expired ones included.
  ///
  /// Use [MsStoreAddOnLicense.isOwnedAt] to decide ownership.
  Future<MsStoreAddOnLicenses> getAddOnLicenses() async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>('getAddOnLicenses');
    return MsStoreAddOnLicenses.fromChannel(map ?? const <Object?, Object?>{});
  }

  /// The add-on licences that have not expired now.
  Future<List<MsStoreAddOnLicense>> getOwnedAddOns() async {
    final DateTime now = _clock();
    return (await getAddOnLicenses()).licenses
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

  /// Reports [quantity] units of the consumable [storeId] as used.
  ///
  /// Pass the same [trackingId] when you retry one fulfilment. A new GUID is
  /// made when it is null.
  Future<MsStoreFulfillmentResult> reportConsumableFulfillment(
    String storeId, {
    int quantity = 1,
    String? trackingId,
  }) async {
    final Map<Object?, Object?>? map = await _channel
        .invokeMapMethod<Object?, Object?>(
          'reportConsumableFulfillment',
          <String, Object?>{
            'storeId': storeId,
            'quantity': quantity,
            'trackingId': trackingId ?? newTrackingId(),
          },
        );
    return MsStoreFulfillmentResult.fromChannel(map);
  }
}
