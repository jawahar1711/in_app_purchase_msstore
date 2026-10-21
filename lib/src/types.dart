import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'channel.dart';

/// A Microsoft Store product, with the Store fields the common
/// [ProductDetails] has no place for.
class MsStoreProductDetails extends ProductDetails {
  /// Creates a product from Store data.
  MsStoreProductDetails({
    required super.id,
    required super.title,
    required super.description,
    required super.price,
    required super.rawPrice,
    required super.currencyCode,
    required this.productKind,
    required this.isSubscription,
    this.subscriptionPeriod,
    this.formattedRecurrencePrice,
  });

  /// Builds a product from a channel `Product` map.
  factory MsStoreProductDetails.fromChannel(Map<Object?, Object?> map) {
    return MsStoreProductDetails(
      id: map['storeId'] as String? ?? '',
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
      price: map['formattedPrice'] as String? ?? '',
      rawPrice: parseUnformattedPrice(map['unformattedPrice'] as String?),
      currencyCode: map['currencyCode'] as String? ?? '',
      productKind: map['productKind'] as String? ?? '',
      isSubscription: map['isSubscription'] as bool? ?? false,
      subscriptionPeriod: map['subscriptionPeriod'] as String?,
      formattedRecurrencePrice: map['formattedRecurrencePrice'] as String?,
    );
  }

  /// The Store product kind: `Durable`, `Consumable`, `UnmanagedConsumable`,
  /// `Application`, or another raw value from the Store.
  final String productKind;

  /// True for a subscription add-on.
  final bool isSubscription;

  /// The billing period, such as `1 Month`, for a subscription.
  final String? subscriptionPeriod;

  /// The formatted price of each renewal, for a subscription.
  final String? formattedRecurrencePrice;
}

/// A purchase or restore result from the Microsoft Store.
class MsStorePurchaseDetails extends PurchaseDetails {
  /// Creates a purchase result.
  MsStorePurchaseDetails({
    super.purchaseID,
    required super.productID,
    required super.transactionDate,
    required super.status,
    this.isConsumable = false,
    this.requestStarted = false,
    this.extendedError,
    this.skuStoreId,
    this.inAppOfferToken,
    this.expirationDate,
  }) : super(
         verificationData: PurchaseVerificationData(
           localVerificationData: '',
           serverVerificationData: '',
           source: msStoreSource,
         ),
       );

  /// True when this came from `buyConsumable`. [completePurchase] fulfils
  /// only consumables.
  final bool isConsumable;

  /// Whether the native Store purchase operation was initiated.
  final bool requestStarted;

  /// The Store's extended error code (HRESULT), when the purchase failed.
  final String? extendedError;

  /// The SKU Store ID, for a restored add-on.
  final String? skuStoreId;

  /// The in-app offer token set in Partner Center, for a restored add-on.
  final String? inAppOfferToken;

  /// When the licence ends, for a restored add-on. Durables get a far-future
  /// date from the Store.
  final DateTime? expirationDate;
}

/// The licence of the app itself.
class MsStoreAppLicense {
  /// Creates an app licence.
  const MsStoreAppLicense({
    required this.isActive,
    required this.isTrial,
    this.trialTimeRemaining,
    this.skuStoreId,
    this.expirationDate,
  });

  /// Builds a licence from the channel map.
  factory MsStoreAppLicense.fromChannel(Map<Object?, Object?> map) {
    final int? seconds = (map['trialTimeRemainingSeconds'] as num?)?.toInt();
    return MsStoreAppLicense(
      isActive: map['isActive'] as bool? ?? false,
      isTrial: map['isTrial'] as bool? ?? false,
      trialTimeRemaining: seconds == null ? null : Duration(seconds: seconds),
      skuStoreId: map['skuStoreId'] as String?,
      expirationDate: parseChannelDate(map['expirationDate']),
    );
  }

  /// True when the app licence is valid (full or trial).
  final bool isActive;

  /// True while the user runs a trial.
  final bool isTrial;

  /// Time left in the trial, when the Store gives it.
  final Duration? trialTimeRemaining;

  /// The SKU Store ID of the app licence.
  final String? skuStoreId;

  /// When the app licence ends.
  final DateTime? expirationDate;
}

/// The licence of one add-on (durable or subscription).
class MsStoreAddOnLicense {
  /// Creates an add-on licence.
  const MsStoreAddOnLicense({
    required this.storeId,
    required this.isActive,
    this.skuStoreId,
    this.inAppOfferToken,
    this.expirationDate,
  });

  /// Builds a licence from a channel `License` map.
  factory MsStoreAddOnLicense.fromChannel(Map<Object?, Object?> map) {
    return MsStoreAddOnLicense(
      storeId: map['storeId'] as String? ?? '',
      isActive: map['isActive'] as bool? ?? false,
      skuStoreId: map['skuStoreId'] as String?,
      inAppOfferToken: map['inAppOfferToken'] as String?,
      expirationDate: parseChannelDate(map['expirationDate']),
    );
  }

  /// The product Store ID.
  final String storeId;

  /// The raw `StoreLicense.IsActive`. Microsoft documents it as always true
  /// for add-ons, so use [isOwnedAt] to decide ownership.
  final bool isActive;

  /// The SKU Store ID.
  final String? skuStoreId;

  /// The in-app offer token set in Partner Center.
  final String? inAppOfferToken;

  /// When the licence ends.
  final DateTime? expirationDate;

  /// True when the licence has not expired at [time].
  bool isOwnedAt(DateTime time) =>
      expirationDate != null && expirationDate!.isAfter(time.toUtc());
}

/// All add-on licences of the signed-in Store user.
class MsStoreAddOnLicenses {
  /// Creates the result.
  const MsStoreAddOnLicenses({
    required this.licenses,
    required this.verifiedOnline,
    this.message,
  });

  /// Builds the result from the channel map.
  factory MsStoreAddOnLicenses.fromChannel(Map<Object?, Object?> map) {
    return MsStoreAddOnLicenses(
      licenses: <MsStoreAddOnLicense>[
        for (final Object? item in map['licenses'] as List<Object?>? ?? [])
          if (item is Map<Object?, Object?>)
            MsStoreAddOnLicense.fromChannel(item),
      ],
      verifiedOnline: map['verifiedOnline'] as bool? ?? false,
      message: map['message'] as String?,
    );
  }

  /// Every add-on licence, expired ones included.
  final List<MsStoreAddOnLicense> licenses;

  /// True only when a complete online collection confirms every emitted
  /// ownership entry; any cached-only entry makes this false.
  final bool verifiedOnline;

  /// A message from the plugin when the Store could not be read.
  final String? message;
}

/// The result of a consumable fulfilment or balance call
/// (`StoreConsumableStatus`).
enum MsStoreFulfillmentStatus {
  /// The call worked.
  succeeded,

  /// The user does not have enough units left.
  insufficientQuantity,

  /// No network.
  networkError,

  /// The Store server failed.
  serverError,

  /// Not a packaged Store app, or no StoreContext.
  unavailable,

  /// Any other result.
  unknown;

  /// Maps a channel status string; unknown text gives [unknown].
  static MsStoreFulfillmentStatus fromChannel(String? value) {
    for (final MsStoreFulfillmentStatus status in values) {
      if (status.name == value) {
        return status;
      }
    }
    return unknown;
  }
}

/// The result of `reportConsumableFulfillment` or `getConsumableBalance`.
class MsStoreFulfillmentResult {
  /// Creates the result.
  const MsStoreFulfillmentResult({
    required this.status,
    this.balanceRemaining,
    this.message,
  });

  /// Builds the result from the channel map.
  factory MsStoreFulfillmentResult.fromChannel(Map<Object?, Object?>? map) {
    return MsStoreFulfillmentResult(
      status: MsStoreFulfillmentStatus.fromChannel(map?['status'] as String?),
      balanceRemaining: (map?['balanceRemaining'] as num?)?.toInt(),
      message: map?['message'] as String?,
    );
  }

  /// The Store status.
  final MsStoreFulfillmentStatus status;

  /// Units left, for a Store-managed consumable.
  final int? balanceRemaining;

  /// A message from the plugin, if any.
  final String? message;
}

/// Parses `StorePrice.UnformattedPrice` into a number.
///
/// The Store gives a plain string whose decimal mark can be `.` or `,`. The
/// last `.` or `,` is taken as the decimal mark when two or fewer digits
/// follow it; every other non-digit is dropped. Returns 0 when nothing parses.
double parseUnformattedPrice(String? value) {
  if (value == null) {
    return 0;
  }
  final String kept = value.replaceAll(RegExp(r'[^0-9.,]'), '');
  final int mark = kept.lastIndexOf(RegExp('[.,]'));
  String normalized;
  if (mark >= 0 && kept.length - mark - 1 <= 2) {
    final String whole = kept.substring(0, mark).replaceAll(RegExp('[.,]'), '');
    normalized = '$whole.${kept.substring(mark + 1)}';
  } else {
    normalized = kept.replaceAll(RegExp('[.,]'), '');
  }
  return double.tryParse(normalized) ?? 0;
}
