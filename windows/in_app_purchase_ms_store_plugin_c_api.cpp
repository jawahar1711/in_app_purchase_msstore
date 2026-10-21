// C ABI entry point. The host app's generated plugin registrant calls
// InAppPurchaseMsStorePluginCApiRegisterWithRegistrar at startup; this shim
// hands the registrar to the C++ plugin class.

#include "include/in_app_purchase_msstore/in_app_purchase_ms_store_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "in_app_purchase_msstore_plugin.h"

void InAppPurchaseMsStorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  in_app_purchase_msstore::InAppPurchaseMsStorePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
