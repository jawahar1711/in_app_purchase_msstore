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

  group('registerWith', () {
    test('sets InAppPurchasePlatform.instance', () {
      InAppPurchaseMsStorePlatform.registerWith();
      expect(
        InAppPurchasePlatform.instance,
        isA<InAppPurchaseMsStorePlatform>(),
      );
    });

    test('sets InAppPurchasePlatformAddition.instance', () {
      InAppPurchaseMsStorePlatform.registerWith();
      expect(
        InAppPurchasePlatformAddition.instance,
        isA<InAppPurchaseMsStorePlatformAddition>(),
      );
    });
  });

  group('isAvailable', () {
    test('true when the C++ side says true', () async {
      store.reply('isAvailable', true);
      expect(await platform.isAvailable(), isTrue);
      expect(store.callsTo('isAvailable'), hasLength(1));
    });

    test('false when the C++ side says false', () async {
      store.reply('isAvailable', false);
      expect(await platform.isAvailable(), isFalse);
    });
  });

  group('queryProductDetails', () {
    test('sends the ids as storeIds', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[],
        'notFound': <Object?>[],
        'error': null,
      });
      await platform.queryProductDetails(<String>{durableId, consumableId});
      final Map<Object?, Object?> args = store.argsOf(
        store.callsTo('queryProducts').single,
      );
      expect((args['storeIds']! as List<Object?>).toSet(), <String>{
        durableId,
        consumableId,
      });
    });

    test('maps every Product field the interface has', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[
          productMap(
            storeId: durableId,
            title: 'Pro unlock',
            description: 'Unlocks everything',
            formattedPrice: '€4,99',
            unformattedPrice: '4.99',
            currencyCode: 'EUR',
          ),
        ],
        'notFound': <Object?>[],
        'error': null,
      });
      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{durableId});
      expect(response.error, isNull);
      expect(response.notFoundIDs, isEmpty);
      final ProductDetails product = response.productDetails.single;
      expect(product.id, durableId);
      expect(product.title, 'Pro unlock');
      expect(product.description, 'Unlocks everything');
      expect(product.price, '€4,99');
      expect(product.rawPrice, 4.99);
      expect(product.currencyCode, 'EUR');
    });

    test('maps subscription and consumable products too', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[
          productMap(storeId: consumableId, productKind: 'Consumable'),
          productMap(
            storeId: 'TESTSUBSCRB01',
            unformattedPrice: '2.99',
            isSubscription: true,
            subscriptionPeriod: '1 Month',
            formattedRecurrencePrice: r'$2.99',
          ),
        ],
        'notFound': <Object?>[],
        'error': null,
      });
      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{consumableId, 'TESTSUBSCRB01'});
      expect(
        response.productDetails.map((ProductDetails p) => p.id),
        unorderedEquals(<String>[consumableId, 'TESTSUBSCRB01']),
      );
      expect(
        response.productDetails
            .firstWhere((ProductDetails p) => p.id == 'TESTSUBSCRB01')
            .rawPrice,
        2.99,
      );
    });

    test('unknown ids go to notFoundIDs', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[productMap(storeId: durableId)],
        'notFound': <Object?>['NOSUCHPRODUCT'],
        'error': null,
      });
      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{durableId, 'NOSUCHPRODUCT'});
      expect(response.productDetails.single.id, durableId);
      expect(response.notFoundIDs, <String>['NOSUCHPRODUCT']);
    });

    test('a Store error becomes an IAPError from msstore', () async {
      store.reply('queryProducts', <String, Object?>{
        'products': <Object?>[],
        'notFound': <Object?>[durableId],
        'error': 'networkError',
      });
      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{durableId});
      expect(response.productDetails, isEmpty);
      expect(response.error, isNotNull);
      expect(response.error!.source, 'msstore');
    });
  });

  // docs/CHANNEL.md "Dart mapping": every PurchaseStatus string.
  const Map<String, PurchaseStatus> purchaseMapping = <String, PurchaseStatus>{
    'succeeded': PurchaseStatus.purchased,
    'alreadyPurchased': PurchaseStatus.restored,
    'notPurchased': PurchaseStatus.canceled,
    'networkError': PurchaseStatus.error,
    'serverError': PurchaseStatus.error,
    'unavailable': PurchaseStatus.error,
    'unknown': PurchaseStatus.error,
  };
  const Set<PurchaseStatus> nonErrors = <PurchaseStatus>{
    PurchaseStatus.purchased,
    PurchaseStatus.restored,
    PurchaseStatus.canceled,
  };

  group('buyNonConsumable', () {
    test('sends the product id as storeId and returns true', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      late bool started;
      await nextBatch(() async {
        started = await platform.buyNonConsumable(
          purchaseParam: paramFor(durableId),
        );
      });
      expect(started, isTrue);
      expect(
        store.argsOf(store.callsTo('purchase').single)['storeId'],
        durableId,
      );
    });

    for (final MapEntry<String, PurchaseStatus> e in purchaseMapping.entries) {
      test('status "${e.key}" -> ${e.value}', () async {
        store.reply('purchase', purchaseReply(e.key));
        final List<PurchaseDetails> batch = await nextBatch(
          () => platform.buyNonConsumable(purchaseParam: paramFor(durableId)),
        );
        final PurchaseDetails details = batch.single;
        expect(details.productID, durableId);
        expect(details.status, e.value);
        if (nonErrors.contains(e.value)) {
          expect(details.error, isNull);
        } else {
          expect(details.error, isNotNull);
          expect(details.error!.source, 'msstore');
          expect(details.error!.code, e.key);
        }
      });
    }

    test('a status string not in the contract is an error', () async {
      store.reply('purchase', purchaseReply('someFutureStatus'));
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.buyNonConsumable(purchaseParam: paramFor(durableId)),
      );
      expect(batch.single.status, PurchaseStatus.error);
      expect(batch.single.error!.source, 'msstore');
    });

    test('never asks the Store to fulfil a durable', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      await nextBatch(
        () => platform.buyNonConsumable(purchaseParam: paramFor(durableId)),
      );
      expect(store.callsTo('reportConsumableFulfillment'), isEmpty);
    });
  });

  group('buyConsumable', () {
    for (final MapEntry<String, PurchaseStatus> e in purchaseMapping.entries) {
      test('status "${e.key}" -> ${e.value}', () async {
        store.reply('purchase', purchaseReply(e.key));
        store.reply(
          'reportConsumableFulfillment',
          fulfillmentReply('succeeded'),
        );
        final List<PurchaseDetails> batch = await nextBatch(
          () => platform.buyConsumable(purchaseParam: paramFor(consumableId)),
        );
        expect(batch.single.productID, consumableId);
        expect(batch.single.status, e.value);
        if (!nonErrors.contains(e.value)) {
          expect(batch.single.error!.code, e.key);
        }
      });
    }

    test(
      'autoConsume: fulfils quantity 1 with a GUID, before emitting',
      () async {
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
        final bool started = await platform.buyConsumable(
          purchaseParam: paramFor(consumableId),
        );
        final List<PurchaseDetails> batch = await next.timeout(
          const Duration(seconds: 5),
        );

        expect(started, isTrue);
        expect(batch.single.status, PurchaseStatus.purchased);
        expect(
          doneWhenEmitted,
          isTrue,
          reason: 'fulfilment must finish before emitting',
        );
        final Map<Object?, Object?> args = store.argsOf(
          store.callsTo('reportConsumableFulfillment').single,
        );
        expect(args['storeId'], consumableId);
        expect(args['quantity'], 1);
        expect(args['trackingId'], matches(guid));
        expect(store.calls.map((c) => c.method).toList(), <String>[
          'purchase',
          'reportConsumableFulfillment',
        ]);
      },
    );

    test('autoConsume: each purchase gets its own trackingId', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      await nextBatch(
        () => platform.buyConsumable(purchaseParam: paramFor(consumableId)),
      );
      await nextBatch(
        () => platform.buyConsumable(purchaseParam: paramFor(consumableId)),
      );
      final List<Object?> ids = store
          .callsTo('reportConsumableFulfillment')
          .map((c) => store.argsOf(c)['trackingId'])
          .toList();
      expect(ids, hasLength(2));
      expect(ids.first, isNot(ids.last));
    });

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
          await nextBatch(
            () => platform.buyConsumable(purchaseParam: paramFor(consumableId)),
          );
          expect(store.callsTo('reportConsumableFulfillment'), isEmpty);
        },
      );
    }

    test('autoConsume false: no fulfilment until completePurchase', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.buyConsumable(
          purchaseParam: paramFor(consumableId),
          autoConsume: false,
        ),
      );
      final PurchaseDetails details = batch.single;
      expect(details.status, PurchaseStatus.purchased);
      expect(details.pendingCompletePurchase, isTrue);
      expect(store.callsTo('reportConsumableFulfillment'), isEmpty);

      await platform.completePurchase(details);
      final Map<Object?, Object?> args = store.argsOf(
        store.callsTo('reportConsumableFulfillment').single,
      );
      expect(args['storeId'], consumableId);
      expect(args['quantity'], 1);
      expect(args['trackingId'], matches(guid));
    });
  });

  group('completePurchase', () {
    test('is a no-op for a durable (the Store has no acknowledge)', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.buyNonConsumable(purchaseParam: paramFor(durableId)),
      );
      final int before = store.calls.length;
      await platform.completePurchase(batch.single);
      expect(store.calls.length, before);
    });

    test('does not fulfil an auto-consumed consumable twice', () async {
      store.reply('purchase', purchaseReply('succeeded'));
      store.reply('reportConsumableFulfillment', fulfillmentReply('succeeded'));
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.buyConsumable(purchaseParam: paramFor(consumableId)),
      );
      await platform.completePurchase(batch.single);
      expect(store.callsTo('reportConsumableFulfillment'), hasLength(1));
    });

    test('is a no-op for a restored purchase', () async {
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
    test('emits restored for each license that has not expired', () async {
      final DateTime now = DateTime.now().toUtc();
      store.reply('getAddOnLicenses', <String, Object?>{
        'licenses': <Object?>[
          // Durables never expire: the Store returns a far-future date.
          licenseMap(
            storeId: durableId,
            expirationDate: DateTime.utc(9999, 12, 31),
          ),
          licenseMap(
            storeId: 'TESTSUBSCRB01',
            expirationDate: now.add(const Duration(days: 20)),
          ),
          licenseMap(
            storeId: 'TESTEXPIRED01',
            expirationDate: now.subtract(const Duration(days: 1)),
          ),
        ],
        'verifiedOnline': true,
        'message': null,
      });
      final List<PurchaseDetails> batch = await nextBatch(
        () => platform.restorePurchases(),
      );
      expect(store.callsTo('getAddOnLicenses'), hasLength(1));
      expect(
        batch.map((PurchaseDetails p) => p.productID),
        unorderedEquals(<String>[durableId, 'TESTSUBSCRB01']),
      );
      for (final PurchaseDetails p in batch) {
        expect(p.status, PurchaseStatus.restored);
        expect(p.error, isNull);
      }
    });

    test(
      'judges by expirationDate, not isActive (always true for add-ons)',
      () async {
        store.reply('getAddOnLicenses', <String, Object?>{
          'licenses': <Object?>[
            licenseMap(
              storeId: 'TESTEXPIRED01',
              expirationDate: DateTime.now().toUtc().subtract(
                const Duration(hours: 1),
              ),
              isActive: true,
            ),
            licenseMap(storeId: durableId, expirationDate: DateTime.utc(9999)),
          ],
          'verifiedOnline': false,
          'message': null,
        });
        final List<PurchaseDetails> batch = await nextBatch(
          () => platform.restorePurchases(),
        );
        expect(batch.map((PurchaseDetails p) => p.productID), <String>[
          durableId,
        ]);
      },
    );
  });

  group('countryCode', () {
    // No Store API gives a country: the Dart side reads the device region.
    test('returns a region code with no Store call', () async {
      expect(await platform.countryCode(), matches(RegExp(r'^([A-Z]{2})?$')));
      expect(store.calls, isEmpty);
    });
  });
}
