import 'dart:async';
import 'package:flutter/services.dart';

class FitPayPermissions {
  const FitPayPermissions({
    required this.overlay,
    required this.usageStats,
    required this.activityRecognition,
  });

  final bool overlay;
  final bool usageStats;
  final bool activityRecognition;

  bool get canStartBlocking => overlay && usageStats;
}

class FitPaySessionSnapshot {
  const FitPaySessionSnapshot({
    required this.active,
    required this.mode,
    required this.goal,
    required this.count,
  });

  final bool active;
  final String mode;
  final int goal;
  final int count;

  factory FitPaySessionSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return FitPaySessionSnapshot(
      active: map['active'] == true,
      mode: map['mode'] as String? ?? 'steps',
      goal: (map['goal'] as num?)?.toInt() ?? 100,
      count: (map['count'] as num?)?.toInt() ?? 0,
    );
  }
}

class FitPaySessionBridge {
  static const MethodChannel _methods =
      MethodChannel('com.example.sweat_and_scroll_app/overlay');
  static const EventChannel _events =
      EventChannel('com.example.sweat_and_scroll_app/session_events');
    static const MethodChannel _poseMethods =
      MethodChannel('com.example.sweat_and_scroll_app/pose');

  static Stream<Map<dynamic, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<dynamic, dynamic>.from(event as Map));

  static Future<FitPayPermissions> checkPermissions() async {
    final result = await _methods.invokeMapMethod<String, bool>('checkPermissions') ??
        const <String, bool>{};
    return FitPayPermissions(
      overlay: result['overlay'] ?? false,
      usageStats: result['usageStats'] ?? false,
      activityRecognition: result['activityRecognition'] ?? false,
    );
  }

  static Future<void> requestOverlayPermission() =>
      _methods.invokeMethod<void>('requestOverlayPermission');

  static Future<void> requestUsageStatsPermission() =>
      _methods.invokeMethod<void>('requestUsageStatsPermission');

  static Future<void> requestActivityRecognitionPermission() =>
      _methods.invokeMethod<void>('requestActivityRecognitionPermission');

  static Future<void> requestNotificationPermission() =>
      _methods.invokeMethod<void>('requestNotificationPermission');

  static Future<void> startSession({
    required String mode,
    required int goal,
    required List<String> packages,
  }) =>
      _methods.invokeMethod<void>('startSession', <String, Object>{
        'mode': mode,
        'goal': goal,
        'packages': packages,
      });

  static Future<void> stopSession() => _methods.invokeMethod<void>('stopSession');

  static Future<FitPaySessionSnapshot> getSessionState() async {
    final result = await _methods.invokeMapMethod<dynamic, dynamic>('getSessionState');
    return FitPaySessionSnapshot.fromMap(result ?? const <dynamic, dynamic>{});
  }

  static Future<bool> processSquatFrame({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotationDegrees,
  }) async {
    return await _poseMethods.invokeMethod<bool>('processSquatFrame', <String, Object>{
          'bytes': bytes,
          'width': width,
          'height': height,
          'rotationDegrees': rotationDegrees,
        }) ??
        false;
  }
}