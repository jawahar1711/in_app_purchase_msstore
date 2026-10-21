import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The channel named in doc/CHANNEL.md.
const MethodChannel storeChannel = MethodChannel(
  'plugins.flutter.dev/in_app_purchase_msstore',
);

/// A stand-in for the C++ side: answers each method from [responses] and
/// records every call it receives, in order.
class FakeStoreChannel {
  FakeStoreChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, _handle);
  }

  String journal = '[]';

  final List<MethodCall> calls = <MethodCall>[];

  /// Method name -> reply, or a function of the call's arguments.
  final Map<String, Object? Function(Object? arguments)> responses =
      <String, Object? Function(Object? arguments)>{};

  void reply(String method, Object? result) =>
      responses[method] = (_) => result;

  List<MethodCall> callsTo(String method) =>
      calls.where((MethodCall c) => c.method == method).toList();

  Map<Object?, Object?> argsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'readPurchaseJournal') return journal;
    if (call.method == 'writePurchaseJournal') {
      journal = call.arguments as String;
      return true;
    }
    if (call.method == 'getPendingConsumables') {
      return {'purchases': <Object?>[]};
    }
    if (call.method == 'isAvailable' && !responses.containsKey(call.method)) {
      return true;
    }
    calls.add(call);
    final Object? Function(Object?)? response = responses[call.method];
    if (response == null) {
      throw MissingPluginException(
        'FakeStoreChannel: no reply for ${call.method}',
      );
    }
    final raw = response(call.arguments);
    final value = raw is Future ? await raw : raw;
    if (call.method == 'purchase' && value is Map) {
      return {...value, 'requestStarted': value['status'] != 'unavailable'};
    }
    return value;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  }
}

/// A `Product` map as the C++ side sends it (doc/CHANNEL.md).
Map<String, Object?> productMap({
  required String storeId,
  String title = 'Title',
  String description = 'Description',
  String formattedPrice = r'$4.99',
  String unformattedPrice = '4.99',
  String currencyCode = 'USD',
  String productKind = 'Durable',
  bool isSubscription = false,
  String? subscriptionPeriod,
  String? formattedRecurrencePrice,
}) => <String, Object?>{
  'storeId': storeId,
  'title': title,
  'description': description,
  'formattedPrice': formattedPrice,
  'unformattedPrice': unformattedPrice,
  'currencyCode': currencyCode,
  'productKind': productKind,
  'isSubscription': isSubscription,
  'subscriptionPeriod': subscriptionPeriod,
  'formattedRecurrencePrice': formattedRecurrencePrice,
};

/// A `License` map as the C++ side sends it (doc/CHANNEL.md).
Map<String, Object?> licenseMap({
  required String storeId,
  required DateTime expirationDate,
  bool isActive = true,
}) => <String, Object?>{
  'storeId': storeId,
  'skuStoreId': '$storeId/0010',
  'inAppOfferToken': 'token_$storeId',
  'expirationDate': expirationDate.toUtc().toIso8601String(),
  'isActive': isActive,
};

/// Name of a status value, whether the Dart side exposes it as an enum or a
/// plain string.
String statusName(Object? status) =>
    status is Enum ? status.name : status.toString();
