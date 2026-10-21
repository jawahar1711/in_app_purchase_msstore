import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';

const MethodChannel _channel = MethodChannel(
  'plugins.flutter.dev/in_app_purchase_msstore',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object?> replies;
  final DateTime now = DateTime.utc(2026, 10, 21, 12);
  late InAppPurchaseMsStorePlatformAddition addition;

  setUp(() {
    calls = <MethodCall>[];
    replies = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          calls.add(call);
          return replies[call.method];
        });
    addition = InAppPurchaseMsStorePlatformAddition(clock: () => now);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('getAppLicense maps a trial', () async {
    replies['getAppLicense'] = <String, Object?>{
      'isActive': true,
      'isTrial': true,
      'trialTimeRemainingSeconds': 3600,
      'skuStoreId': '9APP/0010',
      'expirationDate': '2026-11-01T00:00:00Z',
    };

    final MsStoreAppLicense license = await addition.getAppLicense();

    expect(license.isActive, isTrue);
    expect(license.isTrial, isTrue);
    expect(license.trialTimeRemaining, const Duration(hours: 1));
    expect(license.skuStoreId, '9APP/0010');
    expect(license.expirationDate, DateTime.utc(2026, 11));
  });

  test('getAppLicense with nulls', () async {
    replies['getAppLicense'] = <String, Object?>{
      'isActive': false,
      'isTrial': false,
    };
    final MsStoreAppLicense license = await addition.getAppLicense();
    expect(license.isActive, isFalse);
    expect(license.trialTimeRemaining, isNull);
    expect(license.expirationDate, isNull);
  });

  test('getAddOnLicenses judges ownership by expiry, not isActive', () async {
    replies['getAddOnLicenses'] = <String, Object?>{
      'licenses': <Object?>[
        <String, Object?>{
          'storeId': '9OLD',
          'skuStoreId': '9OLD/0010',
          'inAppOfferToken': 'old',
          'expirationDate': '2026-01-01T00:00:00Z',
          'isActive': true,
        },
      ],
      'verifiedOnline': true,
    };

    final MsStoreAddOnLicenses result = await addition.getAddOnLicenses();

    expect(result.verifiedOnline, isTrue);
    final MsStoreAddOnLicense license = result.licenses.single;
    expect(license.storeId, '9OLD');
    expect(license.isActive, isTrue);
    expect(license.isOwnedAt(now), isFalse);
    expect(license.isOwnedAt(DateTime.utc(2025)), isTrue);
  });

  test('getConsumableBalance', () async {
    replies['getConsumableBalance'] = <String, Object?>{
      'status': 'succeeded',
      'balanceRemaining': 3,
    };
    final MsStoreFulfillmentResult result = await addition.getConsumableBalance(
      '9CON',
    );
    expect(calls.single.arguments, <String, Object?>{'storeId': '9CON'});
    expect(result.status, MsStoreFulfillmentStatus.succeeded);
    expect(result.balanceRemaining, 3);
  });

  test('reportConsumableFulfillment passes quantity and tracking id', () async {
    replies['reportConsumableFulfillment'] = <String, Object?>{
      'status': 'insufficientQuantity',
      'balanceRemaining': 0,
      'message': 'none left',
    };
    final MsStoreFulfillmentResult result = await addition
        .reportConsumableFulfillment(
          '9CON',
          quantity: 5,
          trackingId: '00000000-0000-4000-8000-000000000000',
        );
    expect(calls.single.arguments, <String, Object?>{
      'storeId': '9CON',
      'quantity': 5,
      'trackingId': '00000000-0000-4000-8000-000000000000',
    });
    expect(result.status, MsStoreFulfillmentStatus.insufficientQuantity);
    expect(result.message, 'none left');
  });

  test('fulfilment status strings map, unknown text falls back', () {
    expect(
      MsStoreFulfillmentStatus.fromChannel('networkError'),
      MsStoreFulfillmentStatus.networkError,
    );
    expect(
      MsStoreFulfillmentStatus.fromChannel('serverError'),
      MsStoreFulfillmentStatus.serverError,
    );
    expect(
      MsStoreFulfillmentStatus.fromChannel('unavailable'),
      MsStoreFulfillmentStatus.unavailable,
    );
    expect(
      MsStoreFulfillmentStatus.fromChannel('brandNew'),
      MsStoreFulfillmentStatus.unknown,
    );
    expect(
      MsStoreFulfillmentStatus.fromChannel(null),
      MsStoreFulfillmentStatus.unknown,
    );
  });

  test('parseUnformattedPrice handles dot, comma and junk', () {
    expect(parseUnformattedPrice('4.99'), 4.99);
    expect(parseUnformattedPrice('4,99'), 4.99);
    expect(parseUnformattedPrice('1,299.00'), 1299);
    expect(parseUnformattedPrice('1.299,00'), 1299);
    expect(parseUnformattedPrice(r'$12'), 12);
    expect(parseUnformattedPrice(''), 0);
    expect(parseUnformattedPrice(null), 0);
  });
}
