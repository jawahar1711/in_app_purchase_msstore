// Public C ABI for the in_app_purchase_msstore plugin. Flutter's generated
// `windows/flutter/generated_plugin_registrant.cc` in the host app includes
// this header and calls InAppPurchaseMsStorePluginCApiRegisterWithRegistrar
// at startup. The file name is the snake_case of the pubspec `pluginClass`
// (InAppPurchaseMsStorePluginCApi).

#ifndef FLUTTER_PLUGIN_IN_APP_PURCHASE_MS_STORE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_IN_APP_PURCHASE_MS_STORE_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void InAppPurchaseMsStorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_IN_APP_PURCHASE_MS_STORE_PLUGIN_C_API_H_
