import 'dart:convert';

import 'package:flutter/services.dart';

/// Persisted before Store dispatch, and retained until application delivery is
/// acknowledged. The native writer atomically replaces a flushed local file.
class PurchaseJournal {
  PurchaseJournal(this.channel);
  final MethodChannel channel;
  List<Map<String, Object?>>? _records;

  Future<List<Map<String, Object?>>> read() async {
    if (_records != null) return _records!;
    final raw = await channel.invokeMethod<String>('readPurchaseJournal');
    if (raw == null) throw StateError('No purchase journal from the platform.');
    final decoded = jsonDecode(raw) as List<dynamic>;
    final records = decoded
        .map((dynamic item) => Map<String, Object?>.from(item as Map))
        .toList();
    for (final record in records) {
      if (record['id'] is! String ||
          record['storeId'] is! String ||
          ![
            'attempt',
            'purchased',
            'fulfilling',
            'fulfilled',
          ].contains(record['state'])) {
        throw const FormatException('Invalid purchase journal record.');
      }
    }
    return _records = records;
  }

  Future<void> save(List<Map<String, Object?>> records) async {
    final saved = await channel.invokeMethod<bool>(
      'writePurchaseJournal',
      jsonEncode(records),
    );
    if (saved != true) throw StateError('Purchase journal was not saved.');
    _records = records;
  }

  Future<void> put(Map<String, Object?> record) async {
    final records = await read();
    await save([
      for (final item in records)
        if (item['id'] != record['id']) item,
      Map<String, Object?>.of(record),
    ]);
  }

  Future<void> remove(String id) async => save([
    for (final item in await read())
      if (item['id'] != id) item,
  ]);
}
