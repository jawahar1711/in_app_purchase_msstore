import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

// Placeholder Store IDs. Replace them with the 12-character Store IDs of the
// add-ons you created in Partner Center (your app > Add-ons). The Store ID
// looks like 9NBLGGH4XXXX. It is not the product ID you typed yourself.
const String kDurableId = 'YOUR_DURABLE_STORE_ID';
const String kConsumableId = 'YOUR_CONSUMABLE_STORE_ID';
const String kSubscriptionId = 'YOUR_SUBSCRIPTION_STORE_ID';
const Set<String> kProductIds = {kDurableId, kConsumableId, kSubscriptionId};

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'in_app_purchase_msstore example',
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: const StorePage(),
    );
  }
}

class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  // On Windows this is backed by in_app_purchase_msstore. The package
  // registers itself, so the app code is the same as on Android and iOS.
  final InAppPurchase _iap = InAppPurchase.instance;
  late final StreamSubscription<List<PurchaseDetails>> _subscription;

  bool _loading = true;
  bool _available = false;
  List<ProductDetails> _products = [];
  List<String> _notFound = [];
  final Set<String> _owned = {};
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _subscription = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _addLog('Purchase stream error: $e'),
    );
    _load();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final available = await _iap.isAvailable();
    if (!available) {
      setState(() {
        _available = false;
        _loading = false;
      });
      return;
    }
    final response = await _iap.queryProductDetails(kProductIds);
    if (response.error != null) {
      _addLog(
        'Query error: ${response.error!.code} ${response.error!.message}',
      );
    }
    setState(() {
      _available = true;
      _products = response.productDetails;
      _notFound = response.notFoundIDs;
      _loading = false;
    });
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // A real app verifies the purchase here (for example with the
          // Microsoft Store collections API on its server) before it grants
          // the content, and stores the result.
          if (purchase.productID != kConsumableId) {
            setState(() => _owned.add(purchase.productID));
          }
          _addLog('${purchase.status.name}: ${purchase.productID}');
        case PurchaseStatus.canceled:
          _addLog('Canceled: ${purchase.productID}');
        case PurchaseStatus.error:
          _addLog('Error: ${purchase.error?.code} ${purchase.error?.message}');
        case PurchaseStatus.pending:
          // The Microsoft Store has no pending state. Kept for other stores.
          _addLog('Pending: ${purchase.productID}');
      }
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
    }
  }

  void _buy(ProductDetails product) {
    final param = PurchaseParam(productDetails: product);
    if (product.id == kConsumableId) {
      _iap.buyConsumable(purchaseParam: param);
    } else {
      // Durable add-ons and subscriptions use the same call.
      _iap.buyNonConsumable(purchaseParam: param);
    }
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Microsoft Store purchases'),
        actions: [
          TextButton(
            onPressed: _available ? _iap.restorePurchases : null,
            child: const Text('Restore'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!_available)
                  const Text(
                    'The Store is not available. Run the app as an MSIX '
                    'package that is associated with a Partner Center app. '
                    'See example/README.md.',
                  ),
                for (final product in _products)
                  Card(
                    child: ListTile(
                      title: Text(product.title),
                      subtitle: Text(product.description),
                      trailing: _owned.contains(product.id)
                          ? const Icon(Icons.check_circle)
                          : FilledButton(
                              onPressed: () => _buy(product),
                              child: Text(product.price),
                            ),
                    ),
                  ),
                if (_notFound.isNotEmpty)
                  Text('Not found in the Store: ${_notFound.join(', ')}'),
                const Divider(),
                for (final line in _log) Text(line),
              ],
            ),
    );
  }
}
