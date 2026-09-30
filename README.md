# sweat_and_scroll_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Android SDK configuration

FitPay initializes RevenueCat and OneSignal only when valid build-time values are provided. Keep the keys out of source control and pass the public SDK values at build time:

```powershell
flutter run --dart-define=REVENUECAT_ANDROID_API_KEY=goog_your_public_sdk_key --dart-define=ONESIGNAL_APP_ID=your-onesignal-app-id
```

RevenueCat products and entitlements still need to be created in the RevenueCat dashboard. To verify OneSignal delivery, initialize with the OneSignal App ID, grant notification permission in FitPay, then send a test welcome push from the OneSignal dashboard. Do not put a OneSignal REST API key in the app; push sends must come from the dashboard or a trusted backend.
