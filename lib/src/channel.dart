import 'dart:math';

import 'package:flutter/services.dart';

/// The method channel shared with the C++ plugin. See `docs/CHANNEL.md`.
const MethodChannel msStoreChannel = MethodChannel(
  'plugins.flutter.dev/in_app_purchase_msstore',
);

/// The `source` of every [IAPError] and [InAppPurchaseException] this
/// package creates.
const String msStoreSource = 'msstore';

/// Returns a clock that reads the real time.
DateTime systemClock() => DateTime.now();

final Random _random = Random.secure();

/// A random version 4 GUID string, used as the fulfilment tracking id.
String newTrackingId() {
  final List<int> b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final String hex = b
      .map((int v) => v.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Reads an ISO-8601 date from the channel, or null.
DateTime? parseChannelDate(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
