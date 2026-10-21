import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';

import 'fake_store_channel.dart';

// Contract tests for the Windows-only addition: every License field and
// every FulfillmentStatus string in docs/CHANNEL.md, through the real channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStoreChannel store;
  late InAppPurchaseMsStorePlatformAddition addition;

  setUp(() {
    store = FakeStoreChannel();
    addition = InAppPurchaseMsStorePlatformAddition();
  });

  tearDown(() => store.dispose());

  group('getAddOnLicenses', () {
    test('maps every License field and the wrapper', () async {
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
      final MsStoreAddOnLicenses result = await addition.getAddOnLicenses();
      expect(result.verifiedOnline, isTrue);
      expect(result.message, isNull);
      final MsStoreAddOnLicense license = result.licenses.single;
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
    for (final String status in fulfillmentStatuses) {
      test('status "$status" comes through', () async {
        store.reply('getConsumableBalance', <String, Object?>{
          'status': status,
          'balanceRemaining': status == 'succeeded' ? 3 : null,
        });
        final MsStoreFulfillmentResult balance = await addition
            .getConsumableBalance('TESTCONSUME01');
        expect(statusName(balance.status), status);
        expect(balance.balanceRemaining, status == 'succeeded' ? 3 : isNull);
      });
    }
  });
}
