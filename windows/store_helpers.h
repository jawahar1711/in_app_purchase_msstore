#pragma once

// Store-free helpers for the plugin: status names, argument parsing, date
// and GUID handling. Plain C++ (no WinRT) so the unit tests run without a
// Microsoft Store. Enum arguments are the raw WinRT values; the plugin
// static_asserts that they match Windows.Services.Store.

#include <flutter/encodable_value.h>

#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

namespace in_app_purchase_msstore {
namespace helpers {

// StorePurchaseStatus -> channel status (docs/CHANNEL.md).
inline std::string PurchaseStatusName(int32_t status) {
  switch (status) {
    case 0: return "succeeded";         // Succeeded
    case 1: return "alreadyPurchased";  // AlreadyPurchased
    case 2: return "notPurchased";      // NotPurchased
    case 3: return "networkError";      // NetworkError
    case 4: return "serverError";       // ServerError
    default: return "unknown";
  }
}

// StoreConsumableStatus -> channel status. Microsoft spells member 1
// "InsufficentQuantity"; the channel uses the correct spelling.
inline std::string ConsumableStatusName(int32_t status) {
  switch (status) {
    case 0: return "succeeded";             // Succeeded
    case 1: return "insufficientQuantity";  // InsufficentQuantity
    case 2: return "networkError";          // NetworkError
    case 3: return "serverError";           // ServerError
    default: return "unknown";
  }
}

// StoreSubscriptionInfo billing period as "1 Month" / "3 Months".
// unit is StoreDurationUnit: Minute 0, Hour 1, Day 2, Week 3, Month 4, Year 5.
// Returns "" for a zero period or an unknown unit.
inline std::string SubscriptionPeriod(uint32_t period, int32_t unit) {
  static const char* const kUnits[] = {"Minute", "Hour",  "Day",
                                       "Week",   "Month", "Year"};
  if (period == 0 || unit < 0 || unit > 5) return "";
  std::string text = std::to_string(period) + " " + kUnits[unit];
  if (period != 1) text += "s";
  return text;
}

// AddOnLicenses keys and StoreLicense.SkuStoreId are "<productId>/<skuId>".
inline std::string ProductIdFromSkuStoreId(const std::string& sku_store_id) {
  return sku_store_id.substr(0, sku_store_id.find('/'));
}

// WinRT DateTime ticks (100 ns since 1601-01-01 UTC) -> "YYYY-MM-DDTHH:MM:SSZ".
// Does its own calendar math (Howard Hinnant's civil_from_days) because
// MSVC gmtime stops at year 3000 and durable add-ons expire in year 9999.
inline std::string FormatIsoUtc(int64_t ticks) {
  constexpr int64_t kTicksPerSecond = 10000000LL;
  constexpr int64_t kSecondsPerDay = 86400;
  constexpr int64_t kDays1601To1970 = 134774;
  int64_t seconds = ticks / kTicksPerSecond;
  if (ticks % kTicksPerSecond < 0) --seconds;
  int64_t days = seconds / kSecondsPerDay;
  int64_t second_of_day = seconds % kSecondsPerDay;
  if (second_of_day < 0) {
    second_of_day += kSecondsPerDay;
    --days;
  }
  const int64_t z = days - kDays1601To1970 + 719468;
  const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const int64_t doe = z - era * 146097;
  const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const int64_t mp = (5 * doy + 2) / 153;
  const int64_t day = doy - (153 * mp + 2) / 5 + 1;
  const int64_t month = mp < 10 ? mp + 3 : mp - 9;
  const int64_t year = yoe + era * 400 + (month <= 2 ? 1 : 0);

  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ",
                static_cast<long long>(year), static_cast<long long>(month),
                static_cast<long long>(day),
                static_cast<long long>(second_of_day / 3600),
                static_cast<long long>(second_of_day / 60 % 60),
                static_cast<long long>(second_of_day % 60));
  return buffer;
}

struct GuidParts {
  uint32_t data1 = 0;
  uint16_t data2 = 0;
  uint16_t data3 = 0;
  uint8_t data4[8] = {};
};

// Parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", with or without braces.
inline std::optional<GuidParts> ParseGuid(const std::string& text) {
  std::string s = text;
  if (s.size() == 38 && s.front() == '{' && s.back() == '}') {
    s = s.substr(1, 36);
  }
  if (s.size() != 36) return std::nullopt;
  std::string hex;
  for (size_t i = 0; i < s.size(); ++i) {
    const char c = s[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return std::nullopt;
      continue;
    }
    const bool is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                        (c >= 'A' && c <= 'F');
    if (!is_hex) return std::nullopt;
    hex += c;
  }
  auto read = [&hex](size_t offset, size_t length) {
    return static_cast<uint32_t>(std::stoul(hex.substr(offset, length), nullptr, 16));
  };
  GuidParts guid;
  guid.data1 = read(0, 8);
  guid.data2 = static_cast<uint16_t>(read(8, 4));
  guid.data3 = static_cast<uint16_t>(read(12, 4));
  for (size_t i = 0; i < 8; ++i) {
    guid.data4[i] = static_cast<uint8_t>(read(16 + i * 2, 2));
  }
  return guid;
}

// HRESULT as "0x803F6107".
inline std::string HResultHex(int32_t hresult) {
  char buffer[16];
  std::snprintf(buffer, sizeof(buffer), "0x%08X", static_cast<uint32_t>(hresult));
  return buffer;
}

// --- Method call arguments ------------------------------------------------

// A non-empty String argument, or nullopt.
inline std::optional<std::string> ReadString(const flutter::EncodableMap& args,
                                             const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&it->second);
  if (!value || value->empty()) return std::nullopt;
  return *value;
}

// An int argument. The standard codec sends a Dart int as int32 when it
// fits, otherwise int64.
inline std::optional<int64_t> ReadInt(const flutter::EncodableMap& args,
                                      const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  return std::nullopt;
}

// A List<String> argument of non-empty strings (the list may be empty).
inline std::optional<std::vector<std::string>> ReadStringList(
    const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (!list) return std::nullopt;
  std::vector<std::string> out;
  for (const auto& item : *list) {
    const auto* value = std::get_if<std::string>(&item);
    if (!value || value->empty()) return std::nullopt;
    out.push_back(*value);
  }
  return out;
}

}  // namespace helpers
}  // namespace in_app_purchase_msstore
