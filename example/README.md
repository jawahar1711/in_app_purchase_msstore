# in_app_purchase_msstore example

A small Windows app that lists three Microsoft Store add-ons and buys them
through the standard `in_app_purchase` API. The product IDs in
`lib/main.dart` and the identity values in `pubspec.yaml` are placeholders.
Replace them with your own values from Partner Center.

## 1. Create the app and its add-ons in Partner Center

1. In [Partner Center](https://partner.microsoft.com/dashboard), create (reserve) an app name.
2. Open the app and go to **Add-ons**. Create one add-on of each type you want to test:
   - **Durable** (bought once, owned forever). Set the lifetime to **Forever**.
   - **Developer-managed consumable** (can be bought again after you fulfil it).
   - **Subscription** (optional).
3. Give each add-on a price and a Store listing, then submit it.
4. Open each add-on and copy its **Store ID** (12 characters, for example `9NBLGGH4XXXX`).
   Put the Store IDs in `kDurableId`, `kConsumableId` and `kSubscriptionId` in `lib/main.dart`.

The Store APIs use the Store ID, not the product ID you typed when you created the add-on.

## 2. Package the app as MSIX

The Store APIs only work in a packaged app that has a Store identity. This example uses the
[`msix`](https://pub.dev/packages/msix) package.

1. In Partner Center, open your app > **Product management** > **Product identity**.
2. Copy these values into `msix_config` in `pubspec.yaml`:

   | Partner Center | `msix_config` |
   |---|---|
   | Package/Identity/Name | `identity_name` |
   | Package/Identity/Publisher | `publisher` |
   | Package/Properties/PublisherDisplayName | `publisher_display_name` |

3. Build and package:

   ```sh
   flutter build windows --release
   dart run msix:create --build-windows false
   ```

`store: true` in `msix_config` builds a package for Store upload. The Store signs it.

## 3. Test purchases

Microsoft has no test sandbox for `Windows.Services.Store`, and no way to fake licence data.
Microsoft's [testing steps](https://learn.microsoft.com/en-us/windows/uwp/monetize/in-app-purchases-and-trials#test-your-in-app-purchase-or-trial-implementation):

1. Submit the app and pass certification. You can hide the app from search while you test
   (Partner Center > Pricing and availability).
2. Submit the add-ons.
3. Install the app from the Store once on your test PC, signed in with your test Microsoft account.
4. Run your own build with the same package identity. It then uses the Store licence.

Purchases in a published app are real purchases on the signed-in Microsoft account.

If the app is not linked to a Partner Center app, Store calls fail with extended error
`0x803F6107` ("the Store does not know this app"). The Store APIs also do not work in an app that runs elevated (as administrator).

## Run

```sh
flutter run -d windows
```

`flutter run` starts an unpackaged build, so `isAvailable()` returns `false`. The app still
starts and shows that message. Use the MSIX steps above to test real purchases.
