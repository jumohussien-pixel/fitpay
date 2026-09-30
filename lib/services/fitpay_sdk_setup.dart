import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'fitpay_session_bridge.dart';

class FitPaySdkSetup {
  static const _revenueCatAndroidKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_API_KEY',
    defaultValue: 'goog_REPLACE_WITH_REVENUECAT_PUBLIC_KEY',
  );
  static const _oneSignalAppId = String.fromEnvironment(
    'ONESIGNAL_APP_ID',
    defaultValue: 'REPLACE_WITH_ONESIGNAL_APP_ID',
  );

  static bool _revenueCatReady = false;
  static bool _oneSignalReady = false;

  static bool get oneSignalReady => _oneSignalReady;

  static Future<void> initialize() async {
    if (_isConfigured(_revenueCatAndroidKey)) {
      try {
        await Purchases.configure(PurchasesConfiguration(_revenueCatAndroidKey));
        _revenueCatReady = true;
      } catch (error) {
        reportInitializationError(error);
      }
    }
    if (_isConfigured(_oneSignalAppId)) {
      try {
        await OneSignal.initialize(_oneSignalAppId);
        _oneSignalReady = true;
      } catch (error) {
        reportInitializationError(error);
      }
    }
  }

  static Future<void> requestNotificationPermission() async {
    if (_oneSignalReady) {
      await OneSignal.Notifications.requestPermission(true);
    } else {
      await FitPaySessionBridge.requestNotificationPermission();
    }
  }

  static Future<CustomerInfo?> getCustomerInfo() async {
    if (!_revenueCatReady) return null;
    return Purchases.getCustomerInfo();
  }

  static bool _isConfigured(String value) =>
      value.isNotEmpty && !value.contains('REPLACE_WITH');

  static void reportInitializationError(Object error) {
    debugPrint('FitPay SDK initialization failed: $error');
  }
}