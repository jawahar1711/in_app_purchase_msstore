// Contract tests: they drive the plugin through the channel name and maps
// written in docs/CHANNEL.md, and cover what test/dart_unit_*.dart does not
// (every status on buyConsumable, GUID tracking ids, slow fulfilment,
// completePurchase edge cases, restore with a partial Store answer).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'fake_store_channel.dart';

// Placeholder Store IDs; not real products.
const String durableId = 'TESTDURABLE01';
const String consumableId = 'TESTCONSUME01';

final RegExp guid = RegExp(
  r'^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$',
);

PurchaseParam paramFor(String id) => PurchaseParam(
  productDetails: ProductDetails(
    id: id,
    title: 'Title',
    description: 'Description',
    price: r'$4.99',
    rawPrice: 4.99,
    currencyCode: 'USD',
  ),
);

Map<String, Object?> purchaseReply(String status) => <String, Object?>{
  'status': status,
  'extendedError': status == 'succeeded' ? null : '0x80004005',
  'message': status == 'succeeded' ? null : 'store said $status',
};

Map<String, Object?> fulfillmentReply(String status, {int? balance}) =>
    <String, Object?>{
      'status': status,
      'balanceRemaining': balance,
      'message': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStoreChannel store;
  late InAppPurchaseMsStorePlatform platform;

  setUp(() {
    store = FakeStoreChannel();
    platform = InAppPurchaseMsStorePlatform();
  });

  tearDown(() => store.dispose());

  /// Starts listening before [action] runs, then returns the next batch.
  Future<List<PurchaseDetails>> nextBatch(
    Future<void> Function() action,
  ) async {
    final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
    await action();
    return next.timeout(const Duration(seconds: 5));
  }

  Future<PurchaseDetails> buyConsumable({bool autoConsume = true}) async =>
      (await nextBatch(
        () => platform.buyConsumable(
          purchaseParam: paramFor(consumableId),
          autoConsume: autoConsume,
        ),
      )).single;

  group('channel contract', () {
    test('uses the channel name in docs/CHANNEL.md', () async {
      store.reply('isAvailable', true);
      expect(await platform.isAvailable(), isTrue);
      expect(store.callsTo('isAvailable'), hasLength(1));
    });

    test('queryProducts sends every id as storeIds', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[
          productMap(storeId: consumableId, productKind: 'Consumable'),
          productMap(storeId: durableId, unformattedPrice: '2.99'),
        ],
        'notFound': <Object?>[],
        'error': null,
      });
      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{durableId, consumableId});
      final Map<Object?, Object?> args = store.argsOf(
        store.callsTo('queryProducts').single,
      );
      expect((args['storeIds']! as List<Object?>).toSet(), <String>{
        durableId,
        consumableId,
      });
      expect(
        response.productDetails.map((ProductDetails p) => p.id),
        unorderedEquals(<String>[consumableId, durableId]),
      );
      expect(
        response.productDetails
            .firstWhere((ProductDetails p) => p.id == durableId)
            .rawPrice,
        2.99,
      );
    });
  });

  // docs/CHANNEL.md "Dart mapping": every PurchaseStatus string.
  const Map<String, PurchaseStatus> purchaseMapping = <String, PurchaseStatus>{
    'succeeded': PurchaseStatus.purchased,
    'alreadyPurchased': PurchaseStatus.restored,
    'notPurchased': PurchaseStatus.error,
    'networkError': PurchaseStatus.error,
    'serverError': PurchaseStatus.error,
    'unavailable': PurchaseStatus.error,
    'unknown': PurchaseStatus.error,
  };

  group('buyConsumable', () {
    for (final MapEntry<String, PurchaseStatus> e in purchaseMapping.entries) {
      test('status "${e.key}" -> ${e.value}', () async {
        store.reply('purchase', purchaseReply(e.key));
        store.reply(
          'reportConsumableFulfillment',
          fulfillmentReply('succeeded'),
        );
        final PurchaseDetails details = await buyConsumable();
        expect(details.productID, consumableId);
        expect(details.status, e.value);
        if (e.value == PurchaseStatus.error) {
          expect(details.error!.source, 'msstore');
          expect(details.error!.code, e.key);
        } else {
          expect(details.error, isNull);
        }
      });
    }

    for (final String status in <String>[
      'alreadyPurchased',
      'notPurchased',
      'networkError',
      'serverError',
      'unavailable',
      'unknown',
    ]) {
      test(
        'autoConsume: no fulfilment when the purchase is "$status"',
        () async {
          store.reply('purchase', purchaseReply(status));
          store.reply(
            'reportConsumableFulfillment',
            fulfillmentReply('succeeded'),
          );
          await buyConsumable();
          expect(store.callsTo('reportConsumableFulfillment'), isEmpty);
        },
      );
    }

    test('autoConsume: waits for a slow fulfilment before emitting', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      // The Store answers slowly, so emitting before it answers is caught.
      bool fulfilmentDone = false;
      store.responses['reportConsumableFulfillment'] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        fulfilmentDone = true;
        return fulfillmentReply('succeeded', balance: 0);
      };
      bool? doneWhenEmitted;
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first
          .then((List<PurchaseDetails> b) {
            doneWhenEmitted = fulfilmentDone;
            return b;
          });
      await platform.buyConsumable(purchaseParam: paramFor(consumableId));
      final List<PurchaseDetails> batch = await next.timeout(
        const Duration(seconds: 5),
      );

      expect(batch.single.status, PurchaseStatus.purchased);
      expect(
        doneWhenEmitted,
        isTrue,
        reason: 'fulfilment must finish before emitting',
      );
    });

    test('trackingId is a GUID, also used as purchaseID', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final PurchaseDetails details = await buyConsumable();
      final Map<Object?, Object?> args = store.argsOf(
        store.callsTo('reportConsumableFulfillment').single,
      );
      expect(args['storeId'], consumableId);
      expect(args['quantity'], 1);
      expect(args['trackingId'], matches(guid));
      expect(details.purchaseID, args['trackingId']);
    });

    test('each purchase gets its own trackingId', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final first = await buyConsumable();
      await platform.completePurchase(first);
      await buyConsumable();
      final List<Object?> ids = store
          .callsTo('reportConsumableFulfillment')
          .map((MethodCall c) => store.argsOf(c)['trackingId'])
          .toList();
      expect(ids, hasLength(2));
      expect(ids.first, isNot(ids.last));
    });
  });

  group('completePurchase', () {
    test('does not fulfil an auto-consumed consumable twice', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final PurchaseDetails details = await buyConsumable();
      await platform.completePurchase(details);
      expect(store.callsTo('reportConsumableFulfillment'), hasLength(1));
    });

    test('fulfils an alreadyPurchased consumable once, as a GUID', () async {
      store.reply('purchase', purchaseReply('alreadyPurchased'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final PurchaseDetails details = await buyConsumable();
      expect(details.pendingCompletePurchase, isTrue);

      await platform.completePurchase(details);
      await platform.completePurchase(details);

      final MethodCall call = store
          .callsTo('reportConsumableFulfillment')
          .single;
      expect(store.argsOf(call)['storeId'], consumableId);
      expect(store.argsOf(call)['quantity'], 1);
      expect(store.argsOf(call)['trackingId'], matches(guid));
      expect(details.pendingCompletePurchase, isFalse);
    });

    test('is a no-op for a restored durable', () async {
      store.reply('getAddOnLicenses', <String, Object?>{
        'licenses': <Object?>[
          licenseMap(storeId: durableId, expirationDate: DateTime.utc(9999)),
        ],
        'verifiedOnline': true,
        'message': null,
      });
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.restorePurchases(),
      );
      final int before = store.calls.length;
      await platform.completePurchase(batch.single);
      expect(store.calls.length, before);
    });
  });

  group('restorePurchases', () {
    test('a partial answer with a message still emits what it has', () async {
      // Licences came back but the Store also sent a message (for example,
      // an offline cache): the app still gets the owned add-ons.
      store.reply('getAddOnLicenses', <String, Object?>{
        'licenses': <Object?>[
          licenseMap(storeId: durableId, expirationDate: DateTime.utc(9999)),
        ],
        'verifiedOnline': false,
        'message': 'networkError',
      });
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.restorePurchases(),
      );
      expect(batch.single.productID, durableId);
      expect(batch.single.status, PurchaseStatus.restored);
    });
  });
}
