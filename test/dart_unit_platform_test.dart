import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

const MethodChannel _channel = MethodChannel(
  'plugins.flutter.dev/in_app_purchase_msstore',
);

ProductDetails _product(String id) => ProductDetails(
  id: id,
  title: 't',
  description: 'd',
  price: r'$1.00',
  rawPrice: 1,
  currencyCode: 'USD',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> replies;
  late InAppPurchaseMsStorePlatform platform;
  final DateTime now = DateTime.utc(2026, 10, 21, 12);

  setUp(() {
    calls = <MethodCall>[];
    replies = <String, Object? Function(MethodCall)>{};
    var journal = '[]';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          if (call.method == 'readPurchaseJournal') return journal;
          if (call.method == 'writePurchaseJournal') {
            journal = call.arguments as String;
            return true;
          }
          if (call.method == 'getPendingConsumables') {
            return {'purchases': <Object?>[]};
          }
          if (call.method == 'isAvailable' &&
              !replies.containsKey(call.method)) {
            return true;
          }
          calls.add(call);
          final Object? Function(MethodCall)? reply = replies[call.method];
          if (reply == null) {
            throw MissingPluginException(call.method);
          }
          final value = reply(call);
          if (call.method == 'purchase' && value is Map) {
            return {
              ...value,
              'requestStarted': value['status'] != 'unavailable',
            };
          }
          return value;
        });
    platform = InAppPurchaseMsStorePlatform(clock: () => now);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('registerWith', () {
    test('sets the platform and the addition instances', () {
      InAppPurchaseMsStorePlatform.registerWith();
      expect(
        InAppPurchasePlatform.instance,
        isA<InAppPurchaseMsStorePlatform>(),
      );
      expect(
        InAppPurchasePlatformAddition.instance,
        isA<InAppPurchaseMsStorePlatformAddition>(),
      );
    });
  });

  group('isAvailable', () {
    test('returns the channel bool', () async {
      replies['isAvailable'] = (_) => true;
      expect(await platform.isAvailable(), isTrue);
      replies['isAvailable'] = (_) => false;
      expect(await platform.isAvailable(), isFalse);
    });

    test('is false when the channel returns null', () async {
      replies['isAvailable'] = (_) => null;
      expect(await platform.isAvailable(), isFalse);
    });
  });

  group('queryProductDetails', () {
    test('maps products, notFound and the extra fields', () async {
      replies['queryProducts'] = (_) => <String, Object?>{
        'products': <Object?>[
          <String, Object?>{
            'storeId': '9NBLGGH4R315',
            'title': 'Pro',
            'description': 'All features',
            'formattedPrice': r'$4.99',
            'unformattedPrice': '4.99',
            'currencyCode': 'USD',
            'productKind': 'Durable',
            'isSubscription': true,
            'subscriptionPeriod': '1 Month',
            'formattedRecurrencePrice': r'$4.99',
          },
        ],
        'notFound': <Object?>['9MISSING0000'],
        'error': null,
      };

      final ProductDetailsResponse response = await platform
          .queryProductDetails(<String>{'9NBLGGH4R315', '9MISSING0000'});

      expect(calls.single.method, 'queryProducts');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['storeIds'],
        unorderedEquals(<String>['9NBLGGH4R315', '9MISSING0000']),
      );
      expect(response.error, isNull);
      expect(response.notFoundIDs, <String>['9MISSING0000']);
      final MsStoreProductDetails product =
          response.productDetails.single as MsStoreProductDetails;
      expect(product.id, '9NBLGGH4R315');
      expect(product.title, 'Pro');
      expect(product.description, 'All features');
      expect(product.price, r'$4.99');
      expect(product.rawPrice, 4.99);
      expect(product.currencyCode, 'USD');
      expect(product.productKind, 'Durable');
      expect(product.isSubscription, isTrue);
      expect(product.subscriptionPeriod, '1 Month');
      expect(product.formattedRecurrencePrice, r'$4.99');
    });

    test(
      'a Store error becomes an IAPError and every id is not found',
      () async {
        replies['queryProducts'] = (_) => <String, Object?>{
          'products': <Object?>[],
          'notFound': <Object?>[],
          'error': 'networkError',
        };

        final ProductDetailsResponse response = await platform
            .queryProductDetails(<String>{'9A'});

        expect(response.productDetails, isEmpty);
        expect(response.notFoundIDs, <String>['9A']);
        expect(response.error?.source, 'msstore');
        expect(response.error?.message, 'networkError');
      },
    );
  });

  group('buyNonConsumable', () {
    Future<PurchaseDetails> buy(String status) async {
      replies['purchase'] = (_) => <String, Object?>{
        'status': status,
        'extendedError': status == 'networkError' ? '0x80072EE7' : null,
        'message': status == 'networkError' ? 'offline' : null,
      };
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      final bool started = await platform.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: _product('9DUR')),
      );
      expect(started, status != 'unavailable');
      return (await next).single;
    }

    test('sends the store id', () async {
      await buy('succeeded');
      expect(calls.single.method, 'purchase');
      expect(calls.single.arguments, <String, Object?>{'storeId': '9DUR'});
    });

    test('succeeded -> purchased, nothing to complete', () async {
      final PurchaseDetails p = await buy('succeeded');
      expect(p.productID, '9DUR');
      expect(p.status, PurchaseStatus.purchased);
      expect(p.error, isNull);
      expect(p.pendingCompletePurchase, isFalse);
      expect(p.verificationData.source, 'msstore');
      expect(p.transactionDate, '${now.millisecondsSinceEpoch}');
    });

    test('alreadyPurchased -> restored', () async {
      expect((await buy('alreadyPurchased')).status, PurchaseStatus.restored);
    });

    test('notPurchased -> canceled', () async {
      expect((await buy('notPurchased')).status, PurchaseStatus.canceled);
    });

    for (final String status in <String>[
      'networkError',
      'serverError',
      'unavailable',
      'unknown',
      'somethingNew',
    ]) {
      test('$status -> error with code $status', () async {
        final PurchaseDetails p = await buy(status);
        expect(p.status, PurchaseStatus.error);
        expect(p.error?.source, 'msstore');
        expect(p.error?.code, status);
      });
    }

    test('extendedError is kept', () async {
      final PurchaseDetails p = await buy('networkError');
      expect((p as MsStorePurchaseDetails).extendedError, '0x80072EE7');
      expect(p.error?.message, 'offline');
    });
  });

  group('buyConsumable', () {
    void purchaseReturns(String status) {
      replies['purchase'] = (_) => <String, Object?>{'status': status};
    }

    void fulfillmentReturns(String status) {
      replies['reportConsumableFulfillment'] = (_) => <String, Object?>{
        'status': status,
        'balanceRemaining': 0,
      };
    }

    Future<PurchaseDetails> buy({required bool autoConsume}) async {
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      expect(
        await platform.buyConsumable(
          purchaseParam: PurchaseParam(productDetails: _product('9CON')),
          autoConsume: autoConsume,
        ),
        isTrue,
      );
      return (await next).single;
    }

    test('autoConsume fulfils quantity 1 before emitting', () async {
      purchaseReturns('succeeded');
      fulfillmentReturns('succeeded');

      final PurchaseDetails p = await buy(autoConsume: true);

      expect(calls.map((MethodCall c) => c.method), <String>[
        'purchase',
        'reportConsumableFulfillment',
      ]);
      final Map<Object?, Object?> args =
          calls[1].arguments as Map<Object?, Object?>;
      expect(args['storeId'], '9CON');
      expect(args['quantity'], 1);
      expect(
        args['trackingId'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(p.purchaseID, args['trackingId']);
      expect(p.status, PurchaseStatus.purchased);
      expect(p.pendingCompletePurchase, isTrue);
    });

    test(
      'autoConsume with a failed fulfilment leaves it to complete',
      () async {
        purchaseReturns('succeeded');
        fulfillmentReturns('networkError');

        final PurchaseDetails p = await buy(autoConsume: true);

        expect(p.status, PurchaseStatus.purchased);
        expect(p.pendingCompletePurchase, isTrue);
      },
    );

    test('no autoConsume defers fulfilment to completePurchase', () async {
      purchaseReturns('succeeded');
      fulfillmentReturns('succeeded');

      final PurchaseDetails p = await buy(autoConsume: false);
      expect(calls.single.method, 'purchase');
      expect(p.pendingCompletePurchase, isTrue);

      await platform.completePurchase(p);

      expect(calls.last.method, 'reportConsumableFulfillment');
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['trackingId'],
        p.purchaseID,
      );
      expect(p.pendingCompletePurchase, isFalse);
    });

    test('a canceled consumable is not fulfilled', () async {
      purchaseReturns('notPurchased');
      final PurchaseDetails p = await buy(autoConsume: true);
      expect(calls.single.method, 'purchase');
      expect(p.status, PurchaseStatus.canceled);
      expect(p.pendingCompletePurchase, isFalse);
    });

    test(
      'alreadyPurchased consumable is restored and left to complete',
      () async {
        purchaseReturns('alreadyPurchased');
        final PurchaseDetails p = await buy(autoConsume: true);
        expect(calls.single.method, 'purchase');
        expect(p.status, PurchaseStatus.restored);
        expect(p.pendingCompletePurchase, isTrue);
      },
    );
  });

  group('completePurchase', () {
    test('is a no-op for a durable', () async {
      replies['purchase'] = (_) => <String, Object?>{'status': 'succeeded'};
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      await platform.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: _product('9DUR')),
      );
      final PurchaseDetails p = (await next).single;
      calls.clear();

      await platform.completePurchase(p);

      expect(calls, isEmpty);
    });

    test('a failed fulfilment throws and stays pending', () async {
      replies['purchase'] = (_) => <String, Object?>{'status': 'succeeded'};
      replies['reportConsumableFulfillment'] = (_) => <String, Object?>{
        'status': 'serverError',
        'message': 'boom',
      };
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      await platform.buyConsumable(
        purchaseParam: PurchaseParam(productDetails: _product('9CON')),
        autoConsume: false,
      );
      final PurchaseDetails p = (await next).single;

      await expectLater(
        platform.completePurchase(p),
        throwsA(
          isA<InAppPurchaseException>()
              .having(
                (InAppPurchaseException e) => e.code,
                'code',
                'serverError',
              )
              .having(
                (InAppPurchaseException e) => e.source,
                'source',
                'msstore',
              ),
        ),
      );
      expect(p.pendingCompletePurchase, isTrue);
    });
  });

  group('restorePurchases', () {
    test('emits restored for licences that expire after now', () async {
      replies['getAddOnLicenses'] = (_) => <String, Object?>{
        'licenses': <Object?>[
          <String, Object?>{
            'storeId': '9DUR',
            'skuStoreId': '9DUR/0010',
            'inAppOfferToken': 'pro',
            'expirationDate': '9999-12-31T00:00:00Z',
            'isActive': true,
          },
          <String, Object?>{
            'storeId': '9SUBOLD',
            'skuStoreId': '9SUBOLD/0010',
            'inAppOfferToken': 'monthly',
            'expirationDate': '2026-10-01T00:00:00Z',
            'isActive': true,
          },
          <String, Object?>{
            'storeId': '9SUBNEW',
            'skuStoreId': '9SUBNEW/0010',
            'inAppOfferToken': 'yearly',
            'expirationDate': '2027-10-01T00:00:00Z',
            'isActive': true,
          },
        ],
        'verifiedOnline': true,
        'message': null,
      };

      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      await platform.restorePurchases();
      final List<PurchaseDetails> restored = await next;

      expect(restored.map((PurchaseDetails p) => p.productID), <String>[
        '9DUR',
        '9SUBNEW',
      ]);
      expect(
        restored.every(
          (PurchaseDetails p) => p.status == PurchaseStatus.restored,
        ),
        isTrue,
      );
      final MsStorePurchaseDetails sub = restored[1] as MsStorePurchaseDetails;
      expect(sub.expirationDate, DateTime.utc(2027, 10));
      expect(sub.skuStoreId, '9SUBNEW/0010');
      expect(sub.inAppOfferToken, 'yearly');
      expect(sub.pendingCompletePurchase, isFalse);
    });

    test('emits an empty list when nothing is owned', () async {
      replies['getAddOnLicenses'] = (_) => <String, Object?>{
        'licenses': <Object?>[],
        'verifiedOnline': true,
      };
      final Future<List<PurchaseDetails>> next = platform.purchaseStream.first;
      await platform.restorePurchases();
      expect(await next, isEmpty);
    });

    test('throws when the Store could not be checked', () async {
      replies['getAddOnLicenses'] = (_) => <String, Object?>{
        'licenses': <Object?>[],
        'verifiedOnline': false,
        'message': 'unavailable',
      };
      await expectLater(
        platform.restorePurchases(),
        throwsA(isA<InAppPurchaseException>()),
      );
    });
  });

  group('countryCode', () {
    test('reads the Windows home geographic region', () async {
      replies['countryCode'] = (_) => 'AU';
      expect(await platform.countryCode(), 'AU');
      expect(calls.single.method, 'countryCode');
    });
  });
}
