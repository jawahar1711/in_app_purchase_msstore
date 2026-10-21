import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

const channel = MethodChannel('plugins.flutter.dev/in_app_purchase_msstore');
final param = PurchaseParam(
  productDetails: ProductDetails(
    id: 'TESTCOINS001',
    title: 'Coins',
    description: 'Coins',
    price: '1',
    rawPrice: 1,
    currencyCode: 'USD',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String journal;
  late Map<String, Object?> purchase;
  late List<Map<String, Object?>> owned;
  late Set<String> consumed;
  late List<String> fulfillmentIds;
  late bool losePurchaseResponse;
  late bool loseFulfillmentResponse;
  late bool failJournal;
  late bool available;
  late bool failRecovery;
  late bool failAfterConsumption;
  late Object? license;
  late Object? addons;
  setUp(() {
    journal = '[]';
    purchase = {'status': 'succeeded', 'requestStarted': true};
    owned = [];
    consumed = {};
    fulfillmentIds = [];
    losePurchaseResponse = false;
    loseFulfillmentResponse = false;
    failJournal = false;
    available = true;
    failRecovery = false;
    failAfterConsumption = false;
    license = {'isActive': false, 'isTrial': false};
    addons = {'licenses': [], 'verifiedOnline': true};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments;
          switch (call.method) {
            case 'isAvailable':
              return available;
            case 'readPurchaseJournal':
              return journal;
            case 'writePurchaseJournal':
              if (failJournal) throw PlatformException(code: 'disk');
              journal = args as String;
              return true;
            case 'getPendingConsumables':
              if (failRecovery) return {'message': 'offline'};
              return {'purchases': owned};
            case 'purchase':
              if (losePurchaseResponse) {
                owned = [
                  {'storeId': param.productDetails.id, 'quantity': 1},
                ];
                throw PlatformException(code: 'lost_response');
              }
              return purchase;
            case 'reportConsumableFulfillment':
              final id = (args as Map)['trackingId'] as String;
              fulfillmentIds.add(id);
              consumed.add(id);
              if (failAfterConsumption) failJournal = true;
              if (loseFulfillmentResponse) return {'status': 'networkError'};
              return {'status': 'succeeded'};
            case 'getAppLicense':
              return license;
            case 'getAddOnLicenses':
              return addons;
            case 'countryCode':
              return 'AU';
          }
          throw MissingPluginException(call.method);
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<PurchaseDetails> buy(InAppPurchaseMsStorePlatform p, bool auto) async {
    final next = p.purchaseStream.first;
    await p.buyConsumable(purchaseParam: param, autoConsume: auto);
    return (await next.timeout(const Duration(seconds: 1))).single;
  }

  for (final auto in [false, true]) {
    test('R1 restart before delivery autoConsume=$auto', () async {
      final first = await buy(InAppPurchaseMsStorePlatform(), auto);
      expect(first.pendingCompletePurchase, isTrue);
      final restarted = InAppPurchaseMsStorePlatform();
      final replay = (await restarted.purchaseStream.first.timeout(
        const Duration(seconds: 1),
      )).single;
      expect(replay.purchaseID, first.purchaseID);
      await restarted.completePurchase(replay);
      await restarted.completePurchase(replay);
      expect(consumed, {first.purchaseID});
      expect(fulfillmentIds, hasLength(1));
      expect(jsonDecode(journal), isEmpty);
    });
    test(
      'R1 restart after fulfillment response lost autoConsume=$auto',
      () async {
        loseFulfillmentResponse = true;
        final p = InAppPurchaseMsStorePlatform();
        final first = await buy(p, auto);
        if (!auto) {
          await expectLater(
            p.completePurchase(first),
            throwsA(isA<InAppPurchaseException>()),
          );
        }
        loseFulfillmentResponse = false;
        final restarted = InAppPurchaseMsStorePlatform();
        final replay = (await restarted.purchaseStream.first.timeout(
          const Duration(seconds: 1),
        )).single;
        await restarted.completePurchase(replay);
        expect(fulfillmentIds, [first.purchaseID, first.purchaseID]);
        expect(consumed, hasLength(1));
      },
    );
  }
  test(
    'R1 purchase response lost reconciles Store ownership with saved GUID',
    () async {
      losePurchaseResponse = true;
      await expectLater(
        InAppPurchaseMsStorePlatform().buyConsumable(purchaseParam: param),
        throwsA(isA<PlatformException>()),
      );
      final records = jsonDecode(journal) as List;
      expect(records, hasLength(1));
      final restarted = InAppPurchaseMsStorePlatform();
      final replay = (await restarted.purchaseStream.first.timeout(
        const Duration(seconds: 1),
      )).single;
      expect(replay.purchaseID, (records.single as Map)['id']);
      await restarted.completePurchase(replay);
      expect(consumed, {replay.purchaseID});
    },
  );
  test('R1 recovers Store-owned consumables with no local journal', () async {
    owned = [
      {'storeId': param.productDetails.id, 'quantity': 2},
    ];
    final p = InAppPurchaseMsStorePlatform();
    final batch = await p.purchaseStream.first.timeout(
      const Duration(seconds: 1),
    );
    expect(batch, hasLength(2));
    await Future.wait(batch.map(p.completePurchase));
    expect(consumed, hasLength(2));
    expect(jsonDecode(journal), isEmpty);
  });
  test('R1 journal failure prevents purchase or consumption', () async {
    failJournal = true;
    await expectLater(
      InAppPurchaseMsStorePlatform().buyConsumable(purchaseParam: param),
      throwsA(isA<PlatformException>()),
    );
    expect(consumed, isEmpty);
  });
  test('R1 recovery can be retried in the same session with restore', () async {
    failRecovery = true;
    final p = InAppPurchaseMsStorePlatform();
    final events = <List<PurchaseDetails>>[];
    final errors = <Object>[];
    final sub = p.purchaseStream.listen(events.add, onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(errors, hasLength(1));
    failRecovery = false;
    owned = [
      {'storeId': param.productDetails.id, 'quantity': 1},
    ];
    await p.restorePurchases();
    await Future<void>.delayed(Duration.zero);
    expect(
      events
          .expand((e) => e)
          .where((e) => e.productID == param.productDetails.id),
      hasLength(1),
    );
    await sub.cancel();
  });
  test('R1 confirmed empty recovery releases an unstarted attempt', () async {
    journal = jsonEncode([
      {
        'id': '00000000-0000-4000-8000-000000000001',
        'storeId': param.productDetails.id,
        'state': 'attempt',
        'date': null,
      },
    ]);
    final p = InAppPurchaseMsStorePlatform();
    final sub = p.purchaseStream.listen((_) {});
    await p.buyConsumable(purchaseParam: param, autoConsume: false);
    await sub.cancel();
    expect((jsonDecode(journal) as List).single['state'], 'purchased');
  });
  test(
    'R1 lost journal write after Store consumption reuses the saved GUID',
    () async {
      failAfterConsumption = true;
      await expectLater(
        InAppPurchaseMsStorePlatform().buyConsumable(purchaseParam: param),
        throwsA(isA<PlatformException>()),
      );
      failJournal = false;
      failAfterConsumption = false;
      final p = InAppPurchaseMsStorePlatform();
      final replay = (await p.purchaseStream.first.timeout(
        const Duration(seconds: 1),
      )).single;
      await p.completePurchase(replay);
      expect(fulfillmentIds, [replay.purchaseID, replay.purchaseID]);
      expect(consumed, hasLength(1));
    },
  );
  test(
    'R7 unpackaged purchase returns false before accessing journal',
    () async {
      available = false;
      failJournal = true;
      expect(
        await InAppPurchaseMsStorePlatform().buyConsumable(
          purchaseParam: param,
        ),
        isFalse,
      );
      expect(consumed, isEmpty);
    },
  );
  test('R5 helper refuses a missing retry GUID before dispatch', () async {
    await expectLater(
      InAppPurchaseMsStorePlatformAddition().reportConsumableFulfillment(
        'TESTCOINS001',
      ),
      throwsArgumentError,
    );
    expect(fulfillmentIds, isEmpty);
  });
  test('R5 helper retries lost response with caller GUID', () async {
    const id = '00000000-0000-4000-8000-000000000001';
    final a = InAppPurchaseMsStorePlatformAddition();
    loseFulfillmentResponse = true;
    await a.reportConsumableFulfillment('TESTCOINS001', trackingId: id);
    loseFulfillmentResponse = false;
    await a.reportConsumableFulfillment('TESTCOINS001', trackingId: id);
    expect(fulfillmentIds, [id, id]);
    expect(consumed, hasLength(1));
  });
  test(
    'R6 null and failed app license reads throw; inactive license succeeds',
    () async {
      final a = InAppPurchaseMsStorePlatformAddition();
      expect((await a.getAppLicense()).isActive, isFalse);
      for (final value in [
        null,
        {'isActive': false, 'message': 'HRESULT failure'},
      ]) {
        license = value;
        await expectLater(
          a.getAppLicense(),
          throwsA(isA<InAppPurchaseException>()),
        );
      }
    },
  );
  test('R6 owned helper preserves failed and partial read errors', () async {
    final a = InAppPurchaseMsStorePlatformAddition();
    for (final value in [
      null,
      {'licenses': [], 'message': 'failed'},
      {
        'licenses': [
          {'storeId': 'A', 'expirationDate': '9999-01-01T00:00:00Z'},
        ],
        'message': 'partial',
      },
    ]) {
      addons = value;
      await expectLater(
        a.getOwnedAddOns(),
        throwsA(isA<InAppPurchaseException>()),
      );
    }
  });
  for (final consumable in [false, true]) {
    test(
      'R7 launch boolean distinguishes unavailable and initiated cancellation consumable=$consumable',
      () async {
        final p = InAppPurchaseMsStorePlatform();
        Future<bool> launch() => consumable
            ? p.buyConsumable(purchaseParam: param)
            : p.buyNonConsumable(purchaseParam: param);
        purchase = {'status': 'unavailable', 'requestStarted': false};
        expect(await launch(), isFalse);
        purchase = {'status': 'notPurchased', 'requestStarted': true};
        expect(await launch(), isTrue);
      },
    );
  }
  test(
    'R8 error-bearing NotPurchased preserves error; dismissal cancels',
    () async {
      final p = InAppPurchaseMsStorePlatform();
      purchase = {
        'status': 'notPurchased',
        'requestStarted': true,
        'extendedError': '0x80004005',
        'message': 'Store failed',
      };
      final failed = await buy(p, false);
      expect(failed.status, PurchaseStatus.error);
      expect(failed.error?.details, '0x80004005');
      purchase = {
        'status': 'notPurchased',
        'requestStarted': true,
        'extendedError': '0x800704C7',
      };
      expect((await buy(p, false)).status, PurchaseStatus.canceled);
    },
  );
  test('R9 home geographic region is independent of UI locale', () async {
    expect(await InAppPurchaseMsStorePlatform().countryCode(), 'AU');
  });
}
