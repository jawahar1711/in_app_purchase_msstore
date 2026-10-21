// C++/WinRT implementation of in_app_purchase_msstore. Builds to the method
// channel contract in doc/CHANNEL.md.
//
// Threading: purchase context binding and RequestPurchaseAsync initiation stay
// on the Flutter platform/UI thread. Other Store operations use the thread
// pool. All asynchronous replies return to the captured platform apartment.
//
// Errors: Store failures come back as a status string, never as a
// PlatformException. Only bad arguments use result->Error("bad_args").

#include "in_app_purchase_msstore_plugin.h"
#include "store_helpers.h"
#include "purchase_journal.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <Windows.h>
#include <appmodel.h>       // GetCurrentPackageFullName
#include <ShObjIdl_core.h>  // IInitializeWithWindow

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Services.Store.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.System.UserProfile.h>

#include <chrono>
#include <cstdint>
#include <limits>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace in_app_purchase_msstore {

namespace {

namespace winstore = winrt::Windows::Services::Store;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using SharedResult =
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

constexpr const char* kChannelName =
    "plugins.flutter.dev/in_app_purchase_msstore";


constexpr const char* kUnavailableMessage =
    "The Microsoft Store is unavailable: the app is not running as a "
    "packaged (MSIX) app with Store identity.";

// store_helpers.h maps raw enum values; pin them to the WinRT definitions.
static_assert(static_cast<int32_t>(winstore::StorePurchaseStatus::Succeeded) == 0);
static_assert(static_cast<int32_t>(winstore::StorePurchaseStatus::AlreadyPurchased) == 1);
static_assert(static_cast<int32_t>(winstore::StorePurchaseStatus::NotPurchased) == 2);
static_assert(static_cast<int32_t>(winstore::StorePurchaseStatus::NetworkError) == 3);
static_assert(static_cast<int32_t>(winstore::StorePurchaseStatus::ServerError) == 4);
static_assert(static_cast<int32_t>(winstore::StoreConsumableStatus::Succeeded) == 0);
static_assert(static_cast<int32_t>(winstore::StoreConsumableStatus::InsufficentQuantity) == 1);
static_assert(static_cast<int32_t>(winstore::StoreConsumableStatus::NetworkError) == 2);
static_assert(static_cast<int32_t>(winstore::StoreConsumableStatus::ServerError) == 3);
static_assert(static_cast<int32_t>(winstore::StoreDurationUnit::Minute) == 0);
static_assert(static_cast<int32_t>(winstore::StoreDurationUnit::Year) == 5);

// --- Helpers --------------------------------------------------------------

std::string ToUtf8(const winrt::hstring& wide) { return winrt::to_string(wide); }

// True when the process runs with MSIX package identity.
// GetCurrentPackageFullName returns ERROR_INSUFFICIENT_BUFFER when a package
// name exists but the buffer is too small: the usual "am I packaged?" check.
bool IsPackagedProcess() {
  UINT32 length = 0;
  LONG status = ::GetCurrentPackageFullName(&length, nullptr);
  return status == ERROR_INSUFFICIENT_BUFFER;
}

// StoreContext bound to the app window. Desktop apps must call
// IInitializeWithWindow before any call that shows Store UI, or the dialog
// can hang or open off-screen.
winstore::StoreContext StoreContextForWindow(HWND hwnd) {
  if (!hwnd || !IsWindow(hwnd) || GetWindowThreadProcessId(hwnd, nullptr) != GetCurrentThreadId()) {
    throw winrt::hresult_error(HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE));
  }
  auto context = winstore::StoreContext::GetDefault();
  if (hwnd) {
    auto init = context.as<::IInitializeWithWindow>();
    winrt::check_hresult(init->Initialize(hwnd));
  }
  return context;
}

bool HasInternetAccess() {
  using namespace winrt::Windows::Networking::Connectivity;
  const auto profile = NetworkInformation::GetInternetConnectionProfile();
  return profile && profile.GetNetworkConnectivityLevel() ==
                        NetworkConnectivityLevel::InternetAccess;
}

std::string IsoUtc(const winrt::Windows::Foundation::DateTime& date) {
  return helpers::FormatIsoUtc(date.time_since_epoch().count());
}

std::string HResultMessage(winrt::hresult code) {
  return ToUtf8(winrt::hresult_error(code).message());
}

// Adds "extendedError" and "message" when the Store reports an error code.
void AddExtendedError(EncodableMap* response, winrt::hresult code) {
  if (code.value == 0) return;
  (*response)[EncodableValue("extendedError")] =
      EncodableValue(helpers::HResultHex(code.value));
  (*response)[EncodableValue("message")] = EncodableValue(HResultMessage(code));
}

EncodableMap StatusFailure(const std::string& status, const std::string& message) {
  return EncodableMap{{EncodableValue("status"), EncodableValue(status)},
                      {EncodableValue("message"), EncodableValue(message)}};
}

// Switches back to the platform thread and replies. If the app is shutting
// down and the platform apartment is gone, the reply is dropped.
winrt::Windows::Foundation::IAsyncAction ReplyAsync(
    winrt::apartment_context platform_thread, SharedResult result,
    EncodableValue value) {
  try {
    co_await platform_thread;
  } catch (...) {
    co_return;
  }
  result->Success(value);
}

EncodableMap ProductToMap(const winstore::StoreProduct& product) {
  EncodableMap map;
  map[EncodableValue("storeId")] = EncodableValue(ToUtf8(product.StoreId()));
  map[EncodableValue("title")] = EncodableValue(ToUtf8(product.Title()));
  map[EncodableValue("description")] =
      EncodableValue(ToUtf8(product.Description()));
  map[EncodableValue("productKind")] =
      EncodableValue(ToUtf8(product.ProductKind()));

  if (const auto price = product.Price()) {
    map[EncodableValue("formattedPrice")] =
        EncodableValue(ToUtf8(price.FormattedPrice()));
    map[EncodableValue("unformattedPrice")] =
        EncodableValue(ToUtf8(price.UnformattedPrice()));
    map[EncodableValue("currencyCode")] =
        EncodableValue(ToUtf8(price.CurrencyCode()));
  }

  // Subscription details live on the SKU (StoreSku.SubscriptionInfo).
  bool is_subscription = false;
  if (const auto skus = product.Skus()) {
    for (const auto& sku : skus) {
      if (!sku || !sku.IsSubscription()) continue;
      is_subscription = true;
      if (const auto info = sku.SubscriptionInfo()) {
        const std::string period = helpers::SubscriptionPeriod(
            info.BillingPeriod(),
            static_cast<int32_t>(info.BillingPeriodUnit()));
        if (!period.empty()) {
          map[EncodableValue("subscriptionPeriod")] = EncodableValue(period);
        }
      }
      if (const auto sku_price = sku.Price()) {
        const std::string recurrence =
            ToUtf8(sku_price.FormattedRecurrencePrice());
        if (!recurrence.empty()) {
          map[EncodableValue("formattedRecurrencePrice")] =
              EncodableValue(recurrence);
        }
      }
      break;
    }
  }
  map[EncodableValue("isSubscription")] = EncodableValue(is_subscription);
  return map;
}

EncodableMap LicenseToMap(const std::string& store_id,
                          const std::string& sku_store_id,
                          const std::string& in_app_offer_token,
                          const std::string& expiration_date, bool is_active) {
  return EncodableMap{
      {EncodableValue("storeId"), EncodableValue(store_id)},
      {EncodableValue("skuStoreId"), EncodableValue(sku_store_id)},
      {EncodableValue("inAppOfferToken"), EncodableValue(in_app_offer_token)},
      {EncodableValue("expirationDate"), EncodableValue(expiration_date)},
      {EncodableValue("isActive"), EncodableValue(is_active)},
  };
}

// Flutter's window thread is STA. Keep an MTA alive while coroutines use
// thread-pool threads; resume_background alone does not initialize COM.
struct MtaUsage {
  CO_MTA_USAGE_COOKIE cookie = nullptr;
  HRESULT status = CoIncrementMTAUsage(&cookie);
  ~MtaUsage() { if (cookie) CoDecrementMTAUsage(cookie); }
  MtaUsage() = default;
  MtaUsage(const MtaUsage&) = delete;
  MtaUsage& operator=(const MtaUsage&) = delete;
};

// --- Coroutine handlers ---------------------------------------------------

winrt::fire_and_forget QueryProductsAsync(std::vector<std::string> store_ids,
                                          SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;

  EncodableList products;
  std::set<std::string> found;
  std::optional<std::string> error;
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      error = kUnavailableMessage;
    } else if (!store_ids.empty()) {
      auto context = winstore::StoreContext::GetDefault();
      auto kinds = winrt::single_threaded_vector<winrt::hstring>(
          {L"Durable", L"Consumable", L"UnmanagedConsumable"});
      std::vector<winrt::hstring> ids;
      for (const auto& id : store_ids) ids.push_back(winrt::to_hstring(id));
      auto query = co_await context.GetStoreProductsAsync(
          kinds, winrt::single_threaded_vector<winrt::hstring>(std::move(ids)));
      if (query.ExtendedError().value != 0) {
        error = helpers::HResultHex(query.ExtendedError().value) + ": " +
                HResultMessage(query.ExtendedError());
      }
      if (const auto map = query.Products()) {
        for (const auto& pair : map) {
          const auto product = pair.Value();
          if (!product) continue;
          found.insert(ToUtf8(product.StoreId()));
          products.emplace_back(ProductToMap(product));
        }
      }
    }
  } catch (const winrt::hresult_error& e) {
    error = helpers::HResultHex(e.code().value) + ": " + ToUtf8(e.message());
  } catch (const std::exception& e) {
    error = e.what();
  } catch (...) {
    error = "Unknown error while querying products.";
  }

  EncodableList not_found;
  for (const auto& id : store_ids) {
    if (found.count(id) == 0) not_found.emplace_back(id);
  }
  EncodableMap response{{EncodableValue("products"), EncodableValue(products)},
                        {EncodableValue("notFound"), EncodableValue(not_found)}};
  if (error) response[EncodableValue("error")] = EncodableValue(*error);
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

winrt::fire_and_forget PurchaseAsync(HWND hwnd, std::string store_id,
                                     SharedResult result, PurchaseRequest request = {}) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;
  // Do not suspend to a background thread before opening Store UI.

  EncodableMap response;
  bool request_started = false;
  try {
    winrt::check_hresult(mta.status);
    if (!request && !IsPackagedProcess()) {
      response = StatusFailure("unavailable", kUnavailableMessage);
    } else {
      if (!request) request = [](HWND window, const std::string& id) {
        return StoreContextForWindow(window).RequestPurchaseAsync(winrt::to_hstring(id));
      };
      auto operation = request(hwnd, store_id);
      request_started = true;
      auto purchase = co_await operation;
      response[EncodableValue("status")] = EncodableValue(
          helpers::PurchaseStatusName(static_cast<int32_t>(purchase.Status())));
      AddExtendedError(&response, purchase.ExtendedError());
    }
  } catch (const winrt::hresult_error& e) {
    response = StatusFailure("unknown", ToUtf8(e.message()));
    response[EncodableValue("extendedError")] =
        EncodableValue(helpers::HResultHex(e.code().value));
  } catch (const std::exception& e) {
    response = StatusFailure("unknown", e.what());
  } catch (...) {
    response = StatusFailure("unknown", "Unknown error during purchase.");
  }
  response[EncodableValue("requestStarted")] = EncodableValue(request_started);
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

// Shared by reportConsumableFulfillment and getConsumableBalance.
EncodableMap ConsumableResultToMap(const winstore::StoreConsumableResult& r) {
  EncodableMap response{
      {EncodableValue("status"),
       EncodableValue(helpers::ConsumableStatusName(static_cast<int32_t>(r.Status())))},
      {EncodableValue("balanceRemaining"),
       EncodableValue(static_cast<int64_t>(r.BalanceRemaining()))},
  };
  AddExtendedError(&response, r.ExtendedError());
  return response;
}

winrt::fire_and_forget ReportConsumableFulfillmentAsync(
    std::string store_id, uint32_t quantity, winrt::guid tracking_id,
    SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;

  EncodableMap response;
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      response = StatusFailure("unavailable", kUnavailableMessage);
    } else {
      auto context = winstore::StoreContext::GetDefault();
      auto fulfillment = co_await context.ReportConsumableFulfillmentAsync(
          winrt::to_hstring(store_id), quantity, tracking_id);
      response = ConsumableResultToMap(fulfillment);
    }
  } catch (const winrt::hresult_error& e) {
    response = StatusFailure("unknown", ToUtf8(e.message()));
  } catch (const std::exception& e) {
    response = StatusFailure("unknown", e.what());
  } catch (...) {
    response = StatusFailure("unknown", "Unknown error during fulfillment.");
  }
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

winrt::fire_and_forget GetConsumableBalanceAsync(std::string store_id,
                                                 SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;

  EncodableMap response;
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      response = StatusFailure("unavailable", kUnavailableMessage);
    } else {
      auto context = winstore::StoreContext::GetDefault();
      auto balance = co_await context.GetConsumableBalanceRemainingAsync(
          winrt::to_hstring(store_id));
      response = ConsumableResultToMap(balance);
    }
  } catch (const winrt::hresult_error& e) {
    response = StatusFailure("unknown", ToUtf8(e.message()));
  } catch (const std::exception& e) {
    response = StatusFailure("unknown", e.what());
  } catch (...) {
    response = StatusFailure("unknown", "Unknown error reading the balance.");
  }
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

// Add-on licences from GetAppLicenseAsync, plus durable products in the
// user's collection (GetUserCollectionAsync) that the cached licence lacks.
// "message" is set ONLY on failure: Dart treats empty licences + message as
// an error, and empty licences without a message as "owns nothing".
winrt::fire_and_forget GetAddOnLicensesAsync(SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;

  EncodableList licenses;
  bool verified_online = false;
  std::optional<std::string> failure;
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      failure = kUnavailableMessage;
    } else {
      auto context = winstore::StoreContext::GetDefault();
      std::set<std::string> listed;

      // AddOnLicenses holds only valid licences. StoreLicense.IsActive is
      // always true for add-ons; refunds and expiry remove the entry.
      auto app_license = co_await context.GetAppLicenseAsync();
      if (app_license && app_license.AddOnLicenses()) {
        for (const auto& pair : app_license.AddOnLicenses()) {
          const auto add_on = pair.Value();
          if (!add_on) continue;
          const std::string sku_store_id = ToUtf8(add_on.SkuStoreId());
          const std::string store_id = helpers::ProductIdFromSkuStoreId(
              sku_store_id.empty() ? ToUtf8(pair.Key()) : sku_store_id);
          listed.insert(store_id);
          licenses.emplace_back(LicenseToMap(
              store_id, sku_store_id, ToUtf8(add_on.InAppOfferToken()),
              IsoUtc(add_on.ExpirationDate()), add_on.IsActive()));
        }
      }

      // GetAppLicenseAsync can succeed offline with an empty cached licence.
      // Require internet before and after the collection query and a clean
      // ExtendedError before counting the online answer as verified. A failed
      // online check can still report cached licences, never remove them.
      if (HasInternetAccess()) {
        try {
          auto kinds = winrt::single_threaded_vector<winrt::hstring>({L"Durable"});
          auto query = co_await context.GetUserCollectionAsync(kinds);
          bool complete = query && query.ExtendedError().value == 0 &&
                          query.Products() && HasInternetAccess();
          EncodableList extra;
          std::set<std::string> online;
          if (complete) {
            for (const auto& pair : query.Products()) {
              const auto product = pair.Value();
              if (!product) {
                complete = false;  // A partial response is not evidence.
                break;
              }
              if (!product.IsInUserCollection()) continue;
              const std::string store_id = ToUtf8(product.StoreId());

              // Collection membership counts as ownership. Use the owned
              // SKU's end date when the Store gives one.
              std::string sku_store_id;
              std::string expiration = helpers::CollectionExpiry(0);
              if (const auto skus = product.Skus()) {
                for (const auto& sku : skus) {
                  if (!sku || !sku.IsInUserCollection()) continue;
                  sku_store_id = ToUtf8(sku.StoreId());
                  if (const auto data = sku.CollectionData()) {
                    if (data.EndDate().time_since_epoch().count() > 0) {
                      expiration = helpers::CollectionExpiry(data.EndDate().time_since_epoch().count());
                    }
                  }
                  break;
                }
              }
              if (expiration.empty()) {
                complete = false;
                continue;
              }
              online.insert(store_id);
              extra.emplace_back(LicenseToMap(store_id, sku_store_id,
                                              ToUtf8(product.InAppOfferToken()),
                                              expiration, true));
            }
          }
          if (complete) {
            EncodableList merged;
            for (const auto& item : licenses) {
              const auto& map = std::get<EncodableMap>(item);
              const auto id = helpers::ReadString(map, "storeId");
              if (!id || online.count(*id) == 0) merged.push_back(item);
            }
            for (auto& item : extra) merged.push_back(std::move(item));
            licenses = std::move(merged);
            verified_online = helpers::AggregateVerified(complete, listed, online);
          } else {
            failure = "Incomplete online add-on metadata; cached licenses retained.";
          }
        } catch (const std::exception& e) {
          failure = e.what();
        } catch (...) {
          failure = "Online add-on query failed; cached licenses retained.";
        }
      }
    }
  } catch (const winrt::hresult_error& e) {
    licenses.clear();
    failure = helpers::HResultHex(e.code().value) + ": " + ToUtf8(e.message());
  } catch (const std::exception& e) {
    licenses.clear();
    failure = e.what();
  } catch (...) {
    licenses.clear();
    failure = "Unknown error while reading add-on licenses.";
  }

  EncodableMap response{
      {EncodableValue("licenses"), EncodableValue(licenses)},
      {EncodableValue("verifiedOnline"), EncodableValue(verified_online)}};
  if (failure) response[EncodableValue("message")] = EncodableValue(*failure);
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

// UnmanagedConsumable has one outstanding purchase. Consumable quantity is an
// unspent balance, not a purchase count; Dart must distinguish the product kind.
winrt::fire_and_forget GetPendingConsumablesAsync(SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;
  EncodableList purchases;
  EncodableMap response;
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      // No Store purchases can be made or recovered in an unpackaged app.
    } else {
      if (!HasInternetAccess()) throw std::runtime_error("Consumable recovery requires an online Store query.");
      auto context = winstore::StoreContext::GetDefault();
      auto kinds = winrt::single_threaded_vector<winrt::hstring>({L"Consumable", L"UnmanagedConsumable"});
      auto query = co_await context.GetUserCollectionAsync(kinds);
      if (!query || query.ExtendedError().value != 0 || !query.Products())
        throw std::runtime_error("Could not read consumable ownership.");
      for (const auto& pair : query.Products()) {
        const auto product = pair.Value();
        if (!product) throw std::runtime_error("Incomplete consumable collection.");
        if (!product.IsInUserCollection()) continue;
        uint32_t quantity = 1;
        if (product.ProductKind() == L"Consumable") {
          auto balance = co_await context.GetConsumableBalanceRemainingAsync(product.StoreId());
          if (!balance || balance.Status() != winstore::StoreConsumableStatus::Succeeded ||
              balance.ExtendedError().value != 0)
            throw std::runtime_error("Could not read consumable balance.");
          quantity = balance.BalanceRemaining();
        } else if (product.ProductKind() != L"UnmanagedConsumable") {
          continue;
        }
        if (quantity > 0) purchases.emplace_back(EncodableMap{
            {EncodableValue("storeId"), EncodableValue(ToUtf8(product.StoreId()))},
            {EncodableValue("productKind"), EncodableValue(ToUtf8(product.ProductKind()))},
            {EncodableValue("quantity"), EncodableValue(static_cast<int64_t>(quantity))}});
      }
      if (!HasInternetAccess()) throw std::runtime_error("Connectivity lost during consumable recovery.");
    }
    response[EncodableValue("purchases")] = EncodableValue(purchases);
  } catch (const winrt::hresult_error& e) {
    response[EncodableValue("message")] = EncodableValue(ToUtf8(e.message()));
  } catch (const std::exception& e) {
    response[EncodableValue("message")] = EncodableValue(e.what());
  } catch (...) {
    response[EncodableValue("message")] = EncodableValue("Consumable recovery failed.");
  }
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

// "message" only on failure, as for getAddOnLicenses.
winrt::fire_and_forget GetAppLicenseAsync(SharedResult result) {
  winrt::apartment_context platform_thread;
  MtaUsage mta;

  EncodableMap response{{EncodableValue("isActive"), EncodableValue(false)},
                        {EncodableValue("isTrial"), EncodableValue(false)}};
  try {
    winrt::check_hresult(mta.status);
    co_await winrt::resume_background();
    if (!IsPackagedProcess()) {
      response[EncodableValue("message")] = EncodableValue(kUnavailableMessage);
    } else {
      auto context = winstore::StoreContext::GetDefault();
      auto license = co_await context.GetAppLicenseAsync();
      if (license) {
        response[EncodableValue("isActive")] = EncodableValue(license.IsActive());
        response[EncodableValue("isTrial")] = EncodableValue(license.IsTrial());
        if (license.IsTrial()) {
          const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(
              license.TrialTimeRemaining());
          response[EncodableValue("trialTimeRemainingSeconds")] =
              EncodableValue(static_cast<int64_t>(seconds.count()));
        }
        const std::string sku_store_id = ToUtf8(license.SkuStoreId());
        if (!sku_store_id.empty()) {
          response[EncodableValue("skuStoreId")] = EncodableValue(sku_store_id);
        }
        response[EncodableValue("expirationDate")] =
            EncodableValue(IsoUtc(license.ExpirationDate()));
      } else {
        response[EncodableValue("message")] =
            EncodableValue("The Store returned no app license.");
      }
    }
  } catch (const winrt::hresult_error& e) {
    response[EncodableValue("message")] = EncodableValue(
        helpers::HResultHex(e.code().value) + ": " + ToUtf8(e.message()));
  } catch (const std::exception& e) {
    response[EncodableValue("message")] = EncodableValue(e.what());
  } catch (...) {
    response[EncodableValue("message")] =
        EncodableValue("Unknown error while reading the app license.");
  }
  co_await ReplyAsync(platform_thread, result, EncodableValue(response));
}

bool IsStoreAvailable() {
  if (!IsPackagedProcess()) return false;
  try {
    return static_cast<bool>(winstore::StoreContext::GetDefault());
  } catch (...) {
    return false;
  }
}

}  // namespace

void PurchaseForTesting(HWND hwnd, const std::string& store_id,
    SharedResult result, PurchaseRequest request) {
  PurchaseAsync(hwnd, store_id, std::move(result), std::move(request));
}

// --- Plugin class ---------------------------------------------------------

// static
void InAppPurchaseMsStorePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<InAppPurchaseMsStorePlugin>(registrar);

  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

InAppPurchaseMsStorePlugin::InAppPurchaseMsStorePlugin(
    flutter::PluginRegistrarWindows* registrar)
    : root_hwnd_(nullptr) {
  // GetNativeWindow() is the Flutter view; GA_ROOT walks up to the top-level
  // frame so the Store dialog has the right parent (otherwise it can open
  // behind the app or off-screen on multi-monitor setups).
  if (auto view = registrar->GetView()) {
    HWND view_hwnd = view->GetNativeWindow();
    root_hwnd_ = ::GetAncestor(view_hwnd, GA_ROOT);
    if (!root_hwnd_) root_hwnd_ = view_hwnd;
  }
}

InAppPurchaseMsStorePlugin::~InAppPurchaseMsStorePlugin() = default;

void InAppPurchaseMsStorePlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "isAvailable") {
    // No async Store call: answer synchronously.
    result->Success(EncodableValue(IsStoreAvailable()));
    return;
  }

  if (method == "countryCode") {
    try {
      result->Success(EncodableValue(ToUtf8(
          winrt::Windows::System::UserProfile::GlobalizationPreferences::HomeGeographicRegion())));
    } catch (...) {
      result->Success(EncodableValue(""));
    }
    return;
  }

  if (method == "readPurchaseJournal" || method == "writePurchaseJournal") {
    try {
      if (method == "readPurchaseJournal" && !IsPackagedProcess()) {
        result->Success(EncodableValue("[]"));
        return;
      }
      const auto folder = winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
      const std::filesystem::path path = std::filesystem::path(folder.c_str()) / L"in_app_purchase_msstore" / L"pending.json";
      if (method == "readPurchaseJournal") {
        result->Success(EncodableValue(journal::Read(path)));
      } else {
        const auto text = method_call.arguments() ? std::get_if<std::string>(method_call.arguments()) : nullptr;
        if (!text) { result->Error("bad_args", "Journal must be JSON text."); return; }
        journal::Write(path, *text);
        result->Success(EncodableValue(true));
      }
    } catch (const std::exception& e) {
      result->Error("journal_io", e.what());
    } catch (...) {
      result->Error("journal_io", "Could not access the purchase journal.");
    }
    return;
  }

  // shared_ptr so the coroutine co-owns the result across suspend points.
  SharedResult shared_result(std::move(result));
  static const EncodableMap kNoArgs;
  const auto* args = std::get_if<EncodableMap>(method_call.arguments());

  auto bad_args = [&shared_result](const std::string& message) {
    shared_result->Error("bad_args", message);
  };

  if (method == "queryProducts") {
    const auto store_ids =
        helpers::ReadStringList(args ? *args : kNoArgs, "storeIds");
    if (!store_ids) {
      bad_args("queryProducts requires {storeIds: List<String>} of non-empty strings.");
      return;
    }
    QueryProductsAsync(*store_ids, shared_result);
    return;
  }

  if (method == "purchase") {
    const auto store_id = helpers::ReadString(args ? *args : kNoArgs, "storeId");
    if (!store_id) {
      bad_args("purchase requires {storeId: String}.");
      return;
    }
    PurchaseAsync(root_hwnd_, *store_id, shared_result);
    return;
  }

  if (method == "reportConsumableFulfillment") {
    const EncodableMap& map = args ? *args : kNoArgs;
    const auto store_id = helpers::ReadString(map, "storeId");
    const auto quantity = helpers::ReadInt(map, "quantity");
    const auto tracking_text = helpers::ReadString(map, "trackingId");
    const auto tracking =
        tracking_text ? helpers::ParseGuid(*tracking_text) : std::nullopt;
    if (!store_id || !quantity || *quantity < 1 ||
        *quantity > (std::numeric_limits<uint32_t>::max)() || !tracking) {
      bad_args(
          "reportConsumableFulfillment requires {storeId: String, quantity: "
          "int > 0, trackingId: GUID String}.");
      return;
    }
    winrt::guid tracking_id{};
    tracking_id.Data1 = tracking->data1;
    tracking_id.Data2 = tracking->data2;
    tracking_id.Data3 = tracking->data3;
    for (int i = 0; i < 8; ++i) tracking_id.Data4[i] = tracking->data4[i];
    ReportConsumableFulfillmentAsync(*store_id, static_cast<uint32_t>(*quantity),
                                     tracking_id, shared_result);
    return;
  }

  if (method == "getPendingConsumables") {
    GetPendingConsumablesAsync(shared_result);
    return;
  }

  if (method == "getAddOnLicenses") {
    GetAddOnLicensesAsync(shared_result);
    return;
  }

  if (method == "getAppLicense") {
    GetAppLicenseAsync(shared_result);
    return;
  }

  if (method == "getConsumableBalance") {
    const auto store_id = helpers::ReadString(args ? *args : kNoArgs, "storeId");
    if (!store_id) {
      bad_args("getConsumableBalance requires {storeId: String}.");
      return;
    }
    GetConsumableBalanceAsync(*store_id, shared_result);
    return;
  }

  shared_result->NotImplemented();
}

}  // namespace in_app_purchase_msstore
