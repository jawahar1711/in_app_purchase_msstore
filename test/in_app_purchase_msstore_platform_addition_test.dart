import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';

import 'fake_store_channel.dart';

// Results are read as `dynamic` so these tests pin method and field names
// only, not the Dart worker's result class names.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStoreChannel store;
  late InAppPurchaseMsStorePlatformAddition addition;

  setUp(() {
    store = FakeStoreChannel();
    addition = InAppPurchaseMsStorePlatformAddition();
  });

  tearDown(() => store.dispose());

  group('getAppLicense', () {
    test('maps a trial licence', () async {
      store.reply('getAppLicense', <String, Object?>{
        'isActive': true,
        'isTrial': true,
        'trialTimeRemainingSeconds': 3600,
        'skuStoreId': 'TESTAPP00001/0010',
        'expirationDate': '2026-11-01T00:00:00Z',
      });
      final dynamic license = await addition.getAppLicense();
      expect(store.callsTo('getAppLicense'), hasLength(1));
      expect(license.isActive, isTrue);
      expect(license.isTrial, isTrue);
      expect(license.trialTimeRemaining, const Duration(hours: 1));
      expect(license.skuStoreId, 'TESTAPP00001/0010');
      expect(license.expirationDate, DateTime.utc(2026, 11));
    });

    test('maps a full licence with no trial fields', () async {
      store.reply('getAppLicense', <String, Object?>{
        'isActive': true,
        'isTrial': false,
        'trialTimeRemainingSeconds': null,
        'skuStoreId': null,
        'expirationDate': null,
      });
      final dynamic license = await addition.getAppLicense();
      expect(license.isActive, isTrue);
      expect(license.isTrial, isFalse);
      expect(license.trialTimeRemaining, isNull);
      expect(license.expirationDate, isNull);
    });
  });

  group('getAddOnLicenses', () {
    test('maps every License field', () async {
      store.reply('getAddOnLicenses', <String, Object?>{
        'licenses': <Object?>[
          licenseMap(
            storeId: 'TESTSUBSCRB01',
            expirationDate: DateTime.utc(2026, 12, 1),
          ),
        ],
        'verifiedOnline': true,
        'message': null,
      });
      final dynamic licenses = await addition.getAddOnLicenses();
      final dynamic license = (licenses as List<Object?>).single;
      expect(license.storeId, 'TESTSUBSCRB01');
      expect(license.skuStoreId, 'TESTSUBSCRB01/0010');
      expect(license.inAppOfferToken, 'token_TESTSUBSCRB01');
      expect(license.expirationDate, DateTime.utc(2026, 12, 1));
    });
  });

  // docs/CHANNEL.md: every FulfillmentStatus string.
  const List<String> fulfillmentStatuses = <String>[
    'succeeded',
    'insufficientQuantity',
    'networkError',
    'serverError',
    'unavailable',
    'unknown',
  ];

  group('getConsumableBalance', () {
    test('sends the storeId', () async {
      store.reply('getConsumableBalance', <String, Object?>{
        'status': 'succeeded',
        'balanceRemaining': 3,
      });
      await addition.getConsumableBalance('TESTCONSUME01');
      expect(
        store.argsOf(store.callsTo('getConsumableBalance').single)['storeId'],
        'TESTCONSUME01',
      );
    });

    for (final String status in fulfillmentStatuses) {
      test('status "$status" comes through', () async {
        store.reply('getConsumableBalance', <String, Object?>{
          'status': status,
          'balanceRemaining': status == 'succeeded' ? 3 : null,
        });
        final dynamic balance = await addition.getConsumableBalance(
          'TESTCONSUME01',
        );
        expect(statusName(balance.status), status);
        expect(balance.balanceRemaining, status == 'succeeded' ? 3 : isNull);
      });
    }
  });
}
