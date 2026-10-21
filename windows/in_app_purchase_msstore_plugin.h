// C++ Flutter plugin class for in_app_purchase_msstore. Owns the method
// channel handler that dispatches Dart calls to C++/WinRT StoreContext code.
//
// The plugin holds the top-level HWND so IInitializeWithWindow::Initialize
// can bind StoreContext to the app window. Desktop (non-UWP) apps must do
// this before any call that shows Store UI, or the purchase dialog can hang
// or open off-screen.

#ifndef FLUTTER_PLUGIN_IN_APP_PURCHASE_MSSTORE_PLUGIN_H_
#define FLUTTER_PLUGIN_IN_APP_PURCHASE_MSSTORE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <Windows.h>

#include <memory>
#include <functional>
#include <winrt/Windows.Services.Store.h>

namespace in_app_purchase_msstore {

// Injectable initiation seam: exercises the production coroutine without Store UI.
using PurchaseRequest = std::function<winrt::Windows::Foundation::IAsyncOperation<
    winrt::Windows::Services::Store::StorePurchaseResult>(HWND, const std::string&)>;
void PurchaseForTesting(HWND hwnd, const std::string& store_id,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    PurchaseRequest request);

class InAppPurchaseMsStorePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit InAppPurchaseMsStorePlugin(flutter::PluginRegistrarWindows* registrar);

  ~InAppPurchaseMsStorePlugin() override;

  // Disallow copy and assign.
  InAppPurchaseMsStorePlugin(const InAppPurchaseMsStorePlugin&) = delete;
  InAppPurchaseMsStorePlugin& operator=(const InAppPurchaseMsStorePlugin&) =
      delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  // Root HWND of the Flutter window, cached at registration. The plugin is
  // torn down with the window, so the handle stays valid for its lifetime.
  HWND root_hwnd_;
};

}  // namespace in_app_purchase_msstore

#endif  // FLUTTER_PLUGIN_IN_APP_PURCHASE_MSSTORE_PLUGIN_H_
