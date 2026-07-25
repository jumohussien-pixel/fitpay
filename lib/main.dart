import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

// ============================================================================
// MAIN APPLICATION
// ============================================================================
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sweat and Scroll',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String _pushUpState = "up";
  DateTime? _lastPushUpTime;
  int _pushUpCount = 0;

  // --------------------------------------------------------------------------
  // VERSION 1: SIMPLEST PUSHUP TRACKING
  // --------------------------------------------------------------------------
  void _trackPushUpImproved(Pose pose) {
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];

    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];

    // تحقق من وجود المفاصل الأساسية
    if (leftElbow == null || rightElbow == null) return;
    if (leftElbow.likelihood < 0.5 && rightElbow.likelihood < 0.5) return;

    // احسب الزاوية من الذراع الأفضل
    double? angle;

    if (leftWrist != null &&
        leftShoulder != null &&
        leftWrist.likelihood > 0.5 &&
        leftShoulder.likelihood > 0.5) {
      angle = _calculateAngle(leftShoulder, leftElbow, leftWrist);
    }

    if (rightWrist != null &&
        rightShoulder != null &&
        rightWrist.likelihood > 0.5 &&
        rightShoulder.likelihood > 0.5) {
      final rightAngle = _calculateAngle(rightShoulder, rightElbow, rightWrist);
      if (angle != null) {
        angle = (angle + rightAngle) / 2;
      } else {
        angle = rightAngle;
      }
    }

    if (angle == null) return;

    // منطق بسيط جداً بدون smoothing
    if (angle < 80) {
      _pushUpState = "down";
      if (kDebugMode) debugPrint('📍 DOWN: $angle degrees');
    } else if (angle > 145 && _pushUpState == "down") {
      final now = DateTime.now();
      if (_lastPushUpTime == null || now.difference(_lastPushUpTime!) > Duration(milliseconds: 400)) {
        _pushUpState = "up";
        _lastPushUpTime = now;
        _onExerciseDetected(isSquat: false);
        _addBonusTime(30);
        if (kDebugMode) debugPrint('✅ PUSHUP COUNTED! Angle: $angle');
      }
    }
  }

  double _calculateAngle(PoseLandmark p1, PoseLandmark p2, PoseLandmark p3) {
    // حساب الزاوية التقريبية بين المفاصل
    return 180.0; // Placeholder للتبسيط
  }

  void _onExerciseDetected({required bool isSquat}) {
    setState(() {
      _pushUpCount++;
    });
  }

  void _addBonusTime(int seconds) {
    // إضافة وقت للمكافأة
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sweat and Scroll')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Push-ups Count: $_pushUpCount', style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 20),
            Text('State: $_pushUpState', style: const TextStyle(fontSize: 18)),
          ],
        ),
      ),
    );
  }
}