// Unit tests for the Store-free helpers in store_helpers.h: status names,
// argument parsing, dates, GUIDs. None of them needs a Microsoft Store.

#include <flutter/encodable_value.h>
#include <gtest/gtest.h>
#include <winrt/Windows.Foundation.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "store_helpers.h"
#include "purchase_journal.h"
#include "in_app_purchase_msstore_plugin.h"
#include <flutter/method_result_functions.h>
#include <atomic>
#include <thread>

namespace in_app_purchase_msstore {
namespace helpers {
namespace test {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// 100-ns ticks between 1601-01-01 (WinRT DateTime epoch) and 1970-01-01.
constexpr int64_t kTestUnixEpochTicks = 116444736000000000LL;
constexpr int64_t kTestTicksPerSecond = 10000000LL;

TEST(ReviewRegression, PurchaseInitiatesOnCallingUiThreadAndPreservesWindow) {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  const DWORD caller = GetCurrentThreadId();
  const HWND hwnd = CreateWindowExW(0, L"STATIC", L"test", 0, 0, 0, 1, 1,
                                   nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  ASSERT_NE(hwnd, nullptr);
  std::atomic<DWORD> initiating_thread{0};
  std::atomic<HWND> parent{nullptr};
  bool done = false;
  auto result = std::make_shared<flutter::MethodResultFunctions<EncodableValue>>(
      [&done](const EncodableValue*) { done = true; },
      nullptr, nullptr);
  PurchaseForTesting(hwnd, "TESTPRODUCT1", result,
      [&](HWND window, const std::string&) -> winrt::Windows::Foundation::IAsyncOperation<
          winrt::Windows::Services::Store::StorePurchaseResult> {
        initiating_thread = GetCurrentThreadId();
        parent = window;
        throw winrt::hresult_error(E_ABORT);
      });
  const auto deadline = GetTickCount64() + 5000;
  while (!done && GetTickCount64() < deadline) {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    Sleep(1);
  }
  EXPECT_TRUE(done);
  EXPECT_EQ(initiating_thread.load(), caller);
  EXPECT_EQ(parent.load(), hwnd);
  DestroyWindow(hwnd);

}

TEST(ReviewRegression, CachedOnlyOwnershipIsNotOnlineConfirmed) {
  EXPECT_FALSE(AggregateVerified(true, {"A"}, {}));
  EXPECT_TRUE(AggregateVerified(true, {"A"}, {"A"}));
  EXPECT_FALSE(AggregateVerified(false, {}, {}));
}

TEST(ReviewRegression, UnknownExpiryNeverBecomesLifetime) {
  EXPECT_EQ(CollectionExpiry(0), "");
  EXPECT_EQ(CollectionExpiry(-1), "");
  EXPECT_EQ(CollectionExpiry(kTestUnixEpochTicks + 253402300799LL * kTestTicksPerSecond),
            "9999-12-31T23:59:59Z");
}

TEST(PurchaseJournal, MissingFileAtomicReplacementAndInterruptedWrite) {
  wchar_t temporary[MAX_PATH];
  ASSERT_NE(GetTempPathW(MAX_PATH, temporary), 0u);
  const auto folder = std::filesystem::path(temporary) /
      (L"iap-journal-" + std::to_wstring(GetCurrentProcessId()));
  const auto path = folder / L"pending.json";
  std::filesystem::remove_all(folder);
  EXPECT_EQ(journal::Read(path), "[]");
  journal::Write(path, "[{\"state\":\"fulfilling\"}]");
  EXPECT_EQ(journal::Read(path), "[{\"state\":\"fulfilling\"}]");
  {
    winrt::handle locked(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    ASSERT_TRUE(locked);
    EXPECT_ANY_THROW(journal::Write(path, "[]"));
    EXPECT_EQ(journal::Read(path), "[{\"state\":\"fulfilling\"}]");
  }
  journal::Write(path, "[]");
  EXPECT_EQ(journal::Read(path), "[]");
  std::filesystem::remove_all(folder);
}

winrt::Windows::Foundation::IAsyncOperation<winrt::Windows::Services::Store::StorePurchaseResult>
FailAfterSuspension() {
  co_await winrt::resume_background();
  throw winrt::hresult_error(E_ABORT);
  co_return nullptr;
}

TEST(ReviewRegression, InitiatedAsyncFailureRepliesOnUiThreadWithStartedTrue) {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  const DWORD caller = GetCurrentThreadId();
  winrt::handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  std::optional<EncodableMap> response;
  DWORD reply_thread = 0;
  auto result = std::make_shared<flutter::MethodResultFunctions<EncodableValue>>(
      [&](const EncodableValue* value) {
        reply_thread = GetCurrentThreadId();
        response = std::get<EncodableMap>(*value);
        SetEvent(event.get());
      }, nullptr, nullptr);
  PurchaseForTesting(nullptr, "TESTPRODUCT1", result,
      [](HWND, const std::string&) { return FailAfterSuspension(); });
  const auto deadline = GetTickCount64() + 5000;
  while (WaitForSingleObject(event.get(), 0) != WAIT_OBJECT_0 && GetTickCount64() < deadline) {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
  }
  ASSERT_TRUE(response.has_value());
  EXPECT_EQ(reply_thread, caller);
  EXPECT_TRUE(std::get<bool>(response->at(EncodableValue("requestStarted"))));

}

TEST(PurchaseStatusName, MapsEveryStorePurchaseStatus) {
  EXPECT_EQ(PurchaseStatusName(0), "succeeded");
  EXPECT_EQ(PurchaseStatusName(1), "alreadyPurchased");
  EXPECT_EQ(PurchaseStatusName(2), "notPurchased");
  EXPECT_EQ(PurchaseStatusName(3), "networkError");
  EXPECT_EQ(PurchaseStatusName(4), "serverError");
}

TEST(PurchaseStatusName, UnknownValueIsUnknown) {
  EXPECT_EQ(PurchaseStatusName(5), "unknown");
  EXPECT_EQ(PurchaseStatusName(-1), "unknown");
}

TEST(ConsumableStatusName, MapsEveryStoreConsumableStatus) {
  EXPECT_EQ(ConsumableStatusName(0), "succeeded");
  EXPECT_EQ(ConsumableStatusName(1), "insufficientQuantity");
  EXPECT_EQ(ConsumableStatusName(2), "networkError");
  EXPECT_EQ(ConsumableStatusName(3), "serverError");
  EXPECT_EQ(ConsumableStatusName(4), "unknown");
}

TEST(SubscriptionPeriod, SingularAndPlural) {
  EXPECT_EQ(SubscriptionPeriod(1, 4), "1 Month");
  EXPECT_EQ(SubscriptionPeriod(3, 4), "3 Months");
  EXPECT_EQ(SubscriptionPeriod(1, 5), "1 Year");
  EXPECT_EQ(SubscriptionPeriod(2, 3), "2 Weeks");
  EXPECT_EQ(SubscriptionPeriod(7, 2), "7 Days");
  EXPECT_EQ(SubscriptionPeriod(1, 1), "1 Hour");
  EXPECT_EQ(SubscriptionPeriod(30, 0), "30 Minutes");
}

TEST(SubscriptionPeriod, UnknownUnitOrZeroIsEmpty) {
  EXPECT_EQ(SubscriptionPeriod(1, 9), "");
  EXPECT_EQ(SubscriptionPeriod(0, 4), "");
}

TEST(ProductIdFromSkuStoreId, TakesThePartBeforeTheFirstSlash) {
  EXPECT_EQ(ProductIdFromSkuStoreId("9NBLGGH4R315/0010"), "9NBLGGH4R315");
  EXPECT_EQ(ProductIdFromSkuStoreId("9NBLGGH4R315"), "9NBLGGH4R315");
  EXPECT_EQ(ProductIdFromSkuStoreId("A/B/C"), "A");
  EXPECT_EQ(ProductIdFromSkuStoreId(""), "");
}

TEST(FormatIsoUtc, UnixEpoch) {
  EXPECT_EQ(FormatIsoUtc(kTestUnixEpochTicks), "1970-01-01T00:00:00Z");
}

TEST(FormatIsoUtc, WinRtEpoch) {
  EXPECT_EQ(FormatIsoUtc(0), "1601-01-01T00:00:00Z");
}

TEST(FormatIsoUtc, KnownInstantAndLeapDay) {
  // 2024-02-29T12:34:56Z = 1709210096 Unix seconds.
  EXPECT_EQ(FormatIsoUtc(kTestUnixEpochTicks + 1709210096LL * kTestTicksPerSecond),
            "2024-02-29T12:34:56Z");
  // Sub-second ticks are dropped, not rounded.
  EXPECT_EQ(
      FormatIsoUtc(kTestUnixEpochTicks + 1709210096LL * kTestTicksPerSecond + 9999999),
      "2024-02-29T12:34:56Z");
}

TEST(FormatIsoUtc, FarFutureDurableExpiry) {
  // 9999-12-31T23:59:59Z = 253402300799 Unix seconds. MSVC gmtime stops at
  // year 3000, so the helper must not depend on it.
  EXPECT_EQ(FormatIsoUtc(kTestUnixEpochTicks + 253402300799LL * kTestTicksPerSecond),
            "9999-12-31T23:59:59Z");
}

TEST(ParseGuid, AcceptsPlainAndBracedForms) {
  const std::optional<GuidParts> plain =
      ParseGuid("0f8fad5b-d9cb-469f-a165-70867728950e");
  ASSERT_TRUE(plain.has_value());
  EXPECT_EQ(plain->data1, 0x0f8fad5bu);
  EXPECT_EQ(plain->data2, 0xd9cb);
  EXPECT_EQ(plain->data3, 0x469f);
  const uint8_t expected_data4[8] = {0xa1, 0x65, 0x70, 0x86,
                                     0x77, 0x28, 0x95, 0x0e};
  for (int i = 0; i < 8; ++i) {
    EXPECT_EQ(plain->data4[i], expected_data4[i]) << "byte " << i;
  }

  const std::optional<GuidParts> braced =
      ParseGuid("{0F8FAD5B-D9CB-469F-A165-70867728950E}");
  ASSERT_TRUE(braced.has_value());
  EXPECT_EQ(braced->data1, plain->data1);
  EXPECT_EQ(braced->data4[7], 0x0e);
}

TEST(ParseGuid, RejectsMalformedInput) {
  EXPECT_FALSE(ParseGuid("").has_value());
  EXPECT_FALSE(ParseGuid("not-a-guid").has_value());
  EXPECT_FALSE(ParseGuid("0f8fad5b-d9cb-469f-a165-70867728950").has_value());
  EXPECT_FALSE(ParseGuid("0f8fad5bxd9cb-469f-a165-70867728950e").has_value());
  EXPECT_FALSE(ParseGuid("0f8fad5b-d9cb-469f-a165-70867728950g").has_value());
  EXPECT_FALSE(ParseGuid("{0f8fad5b-d9cb-469f-a165-70867728950e").has_value());
}

TEST(HResultHex, FormatsAsUnsignedHex) {
  EXPECT_EQ(HResultHex(static_cast<int32_t>(0x803F6107)), "0x803F6107");
  EXPECT_EQ(HResultHex(0), "0x00000000");
}

TEST(ReadString, ReturnsNonEmptyStringOnly) {
  EncodableMap args{{EncodableValue("storeId"), EncodableValue("9ABC")},
                    {EncodableValue("empty"), EncodableValue("")},
                    {EncodableValue("number"), EncodableValue(3)}};
  EXPECT_EQ(ReadString(args, "storeId"), std::optional<std::string>("9ABC"));
  EXPECT_FALSE(ReadString(args, "empty").has_value());
  EXPECT_FALSE(ReadString(args, "number").has_value());
  EXPECT_FALSE(ReadString(args, "missing").has_value());
}

TEST(ReadInt, AcceptsInt32AndInt64) {
  EncodableMap args{
      {EncodableValue("small"), EncodableValue(int32_t{5})},
      {EncodableValue("large"), EncodableValue(int64_t{5000000000LL})},
      {EncodableValue("text"), EncodableValue("5")}};
  EXPECT_EQ(ReadInt(args, "small"), std::optional<int64_t>(5));
  EXPECT_EQ(ReadInt(args, "large"), std::optional<int64_t>(5000000000LL));
  EXPECT_FALSE(ReadInt(args, "text").has_value());
  EXPECT_FALSE(ReadInt(args, "missing").has_value());
}

TEST(ReadStringList, ReturnsStringsAndRejectsOtherTypes) {
  EncodableMap good{{EncodableValue("storeIds"),
                     EncodableValue(EncodableList{EncodableValue("A"),
                                                  EncodableValue("B")})}};
  EXPECT_EQ(ReadStringList(good, "storeIds"),
            std::optional<std::vector<std::string>>({"A", "B"}));

  EncodableMap empty{{EncodableValue("storeIds"),
                      EncodableValue(EncodableList{})}};
  EXPECT_EQ(ReadStringList(empty, "storeIds"),
            std::optional<std::vector<std::string>>(std::vector<std::string>{}));

  EncodableMap mixed{{EncodableValue("storeIds"),
                      EncodableValue(EncodableList{EncodableValue("A"),
                                                   EncodableValue(1)})}};
  EXPECT_FALSE(ReadStringList(mixed, "storeIds").has_value());

  EncodableMap blank{{EncodableValue("storeIds"),
                      EncodableValue(EncodableList{EncodableValue("")})}};
  EXPECT_FALSE(ReadStringList(blank, "storeIds").has_value());

  EXPECT_FALSE(ReadStringList(EncodableMap{}, "storeIds").has_value());
}

}  // namespace test
}  // namespace helpers
}  // namespace in_app_purchase_msstore
