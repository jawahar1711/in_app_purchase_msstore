# in_app_purchase_msstore: one-page summary

## What it is

An unofficial Windows implementation of Flutter's `in_app_purchase` plugin. Apps keep
calling `InAppPurchase.instance`; on Windows the calls go to the Microsoft Store
(`Windows.Services.Store.StoreContext`). No other package on pub.dev implements the
official interface for Windows (checked 2026-10-21). Flutter's own request for this,
[flutter/flutter#97050](https://github.com/flutter/flutter/issues/97050), is open since 2022.

## Parts

| Part | Where |
|---|---|
| Dart platform class `InAppPurchaseMsStorePlatform` and `InAppPurchaseMsStorePlatformAddition` | `lib/` |
| C++/WinRT plugin (StoreContext calls, window handle set up) | `windows/` |
| Dart <-> C++ method channel contract | `docs/CHANNEL.md` |
| Unit tests (mocked method channel) | `test/` |
| Example app, Partner Center and MSIX steps | `example/` |
| CI: Ubuntu (format, analyze, test) and Windows (test, build example) | `.github/workflows/ci.yml` |

Licence: BSD-3-Clause, copyright Trueframe Digital (same licence as flutter/packages).

## Status

| Check | Result |
|---|---|
| Unit tests | TODO lead-support: count after merge |
| GitHub-hosted CI (Ubuntu + Windows) | TODO lead-support: run URL |
| Codex review | TODO lead-support |
| Real Store purchase on Windows | Not done. Needs a Partner Center test app with add-ons |

## Known limits

* No pending state and no client receipts on the Microsoft Store.
* Testing needs a published (hidden is fine) Partner Center app; Microsoft has no sandbox.
* Subscriptions work like durables: no upgrade, downgrade or offer codes.
* `countryCode()` returns the device home region; the Store has no API for it.

## Founder decisions before going public

1. Go public on GitHub and publish to pub.dev (a pub.dev version can never be deleted).
2. pub.dev publisher. Proposal: verified publisher on `trueframedigital.app`.
3. A Partner Center test app with one durable and one consumable add-on, for a real purchase check.
