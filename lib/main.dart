import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Camera init error: $e");
  }
  runApp(const FitPayApp());
}

// --------------- Bolt Aesthetic Colors ---------------
class BoltColors {
  static const Color bg = Color(0xFF0D0D12);
  static const Color surface = Color(0xFF161620);
  static const Color surfaceLight = Color(0xFF1F1F2E);
  static const Color neon = Color(0xFF00F0FF);
  static const Color success = Color(0xFF00E676);
  static const Color danger = Color(0xFFFF1744);
  static const Color warning = Color(0xFFFFC107);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFB0B0C0);
  static const Color border = Color(0x14FFFFFF); // 8% white
}

// --------------- User Level Enum ---------------
enum UserLevel { beginner, intermediate, advanced }

// --------------- Workout Preference ---------------
enum WorkoutMode { walkingOnly, squatsOnly, both }

// --------------- App ---------------
class FitPayApp extends StatelessWidget {
  const FitPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Fitpay',
      theme: ThemeData(
        scaffoldBackgroundColor: BoltColors.bg,
        brightness: Brightness.dark,
        primaryColor: BoltColors.neon,
        colorScheme: const ColorScheme.dark(
          primary: BoltColors.neon,
          secondary: BoltColors.neon,
          surface: BoltColors.surface,
        ),
        fontFamily: 'Roboto',
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: BoltColors.surface,
          selectedItemColor: BoltColors.neon,
          unselectedItemColor: BoltColors.textSecondary,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// --------------- Main Screen with Bottom Navigation & State ---------------
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const platform = MethodChannel('com.fitpay.app/overlay');

  // ---------- Camera & ML Kit ----------
  CameraController? controller;
  PoseDetector? _poseDetector;
  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String? _cameraError;
  Pose? _latestPose;
  Size? _imageSize;
  bool _isFrontCamera = true;

  // ---------- Exercise State ----------
  int points = 0;
  int squatsCount = 0;
  UserLevel level = UserLevel.beginner;
  String _squatState = "up";
  DateTime? _lastSquatTime;
  final List<double> _squatAngleBuffer = [];

  // ---------- Timer & Blocking ----------
  int _allowedScrollTime = 120; // default 2 minutes
  final int _maxScrollTime = 600;
  Timer? _scrollTimer;
  bool _isAppBlocked = false;
  bool _showSuccessFlash = false;

  // ---------- App Blocking ----------
  bool _isBlockingServiceEnabled = false;
  final Map<String, Map<String, dynamic>> _appsToBlock = {
    'com.zhiliaoapp.musically': {
      'name': 'TikTok',
      'blocked': true,
      'icon': Icons.video_library_rounded
    },
    'com.instagram.android': {
      'name': 'Instagram',
      'blocked': true,
      'icon': Icons.camera_alt_rounded
    },
    'com.google.android.youtube': {
      'name': 'YouTube Shorts',
      'blocked': false,
      'icon': Icons.play_circle_fill_rounded
    },
    'com.facebook.katana': {
      'name': 'Facebook Reels',
      'blocked': false,
      'icon': Icons.facebook_rounded
    },
  };

  // ---------- Gamification & Streak ----------
  int _streak = 0;
  String _lastWorkoutDate = '';
  String _selectedMotivation = 'Reduce screen time';
  WorkoutMode _workoutMode = WorkoutMode.both;
  int _dailyTargetScrollMinutes = 30;
  double _dailyScreenHours = 6.0;

  // ---------- Onboarding ----------
  bool _onboardingComplete = false;

  // ---------- Admin ----------
  bool _isAdminVisible = false;
  int _adminTapCount = 0;

  // ---------- Animations ----------
  late final AnimationController _pulseController;
  late final AnimationController _repController;

  // ---------- Pedometer for walking mode ----------
  StreamSubscription<AccelerometerEvent>? _accelSub;
  int _stepCount = 0;
  double _lastMagnitude = 0;
  bool _isWalking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _repController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      lowerBound: 0.9,
      upperBound: 1.15,
      value: 1.0,
    );

    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.accurate,
        mode: PoseDetectionMode.stream,
      ),
    );

    _loadData();
    _checkPermissions();
    _initializeCamera();
    _startUsageLimitTimer();
    _startPedometer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _repController.dispose();
    _stopStreamSafely();
    controller?.dispose();
    _poseDetector?.close();
    _scrollTimer?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = controller;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopStreamSafely();
    } else if (state == AppLifecycleState.resumed) {
      if (_isAppBlocked) _forceCloseBackgroundApps();
      if (_isCameraInitialized && !_isStreaming) _startStreamSafely();
    }
  }

  // ---------- Permissions ----------
  Future<void> _checkPermissions() async {
    try {
      final bool hasPermission =
          await platform.invokeMethod('checkPermissions') ?? false;
      setState(() => _isBlockingServiceEnabled = hasPermission);
    } catch (_) {}
  }

  Future<void> _requestBlockingPermission() async {
    try {
      await platform.invokeMethod('requestPermissions');
      _checkPermissions();
    } catch (e) {
      _showErrorSnackBar(
          "Open device settings to grant overlay and usage access.");
    }
  }

  // ---------- Timer ----------
  void _startUsageLimitTimer() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_allowedScrollTime > 0) {
        setState(() => _allowedScrollTime--);
      } else {
        if (!_isAppBlocked) {
          setState(() => _isAppBlocked = true);
          _forceCloseBackgroundApps();
        }
      }
    });
  }

  // ---------- Blocking ----------
  Future<void> _forceCloseBackgroundApps() async {
    try {
      final blockedPackages = _appsToBlock.entries
          .where((e) => e.value['blocked'] == true)
          .map((e) => e.key)
          .toList();
      await platform.invokeMethod('blockApps', {'packages': blockedPackages});
    } catch (_) {}
  }

  void _addBonusTime(int seconds) {
    if (!mounted) return;
    setState(() {
      _allowedScrollTime =
          (_allowedScrollTime + seconds).clamp(0, _maxScrollTime);
      _isAppBlocked = false;
      _showSuccessFlash = true;
    });
    HapticFeedback.mediumImpact();
    _repController.forward().then((_) {
      if (mounted) _repController.reverse();
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });
    try {
      platform.invokeMethod('unblockScreen');
    } catch (_) {}
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: BoltColors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ---------- Data Persistence ----------
  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      points = prefs.getInt('points') ?? 0;
      squatsCount = prefs.getInt('squatsCount') ?? 0;
      final savedLevel = prefs.getInt('level') ?? 0;
      level = UserLevel.values[savedLevel.clamp(0, UserLevel.values.length - 1)];
      _allowedScrollTime =
          prefs.getInt('scroll_time') ?? 120;
      _streak = prefs.getInt('streak') ?? 0;
      _lastWorkoutDate = prefs.getString('last_workout_date') ?? '';
      _dailyTargetScrollMinutes =
          prefs.getInt('daily_target_minutes') ?? 30;
      _dailyScreenHours = prefs.getDouble('daily_screen_hours') ?? 6.0;
      _selectedMotivation =
          prefs.getString('motivation') ?? 'Reduce screen time';
      final modeIdx = prefs.getInt('workout_mode') ?? 2;
      _workoutMode = WorkoutMode.values[modeIdx.clamp(0, 2)];
      _onboardingComplete = prefs.getBool('onboarding_done') ?? false;

      // apps block state
      for (final entry in _appsToBlock.entries) {
        final key = 'block_${entry.key}';
        if (prefs.containsKey(key)) {
          entry.value['blocked'] = prefs.getBool(key) ?? true;
        }
      }
    });
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('points', points);
    await prefs.setInt('squatsCount', squatsCount);
    await prefs.setInt('level', level.index);
    await prefs.setInt('scroll_time', _allowedScrollTime);
    await prefs.setInt('streak', _streak);
    await prefs.setString('last_workout_date', _lastWorkoutDate);
    await prefs.setInt('daily_target_minutes', _dailyTargetScrollMinutes);
    await prefs.setDouble('daily_screen_hours', _dailyScreenHours);
    await prefs.setString('motivation', _selectedMotivation);
    await prefs.setInt('workout_mode', _workoutMode.index);
    await prefs.setBool('onboarding_done', _onboardingComplete);
    for (final entry in _appsToBlock.entries) {
      await prefs.setBool('block_${entry.key}', entry.value['blocked']);
    }
  }

  // ---------- Camera & ML Kit ----------
  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = "No camera found.");
      return;
    }
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras[0],
    );
    _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
    controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await controller!.initialize();
      if (!mounted) return;
      await _startStreamSafely();
      setState(() {
        _isCameraInitialized = true;
        _cameraError = null;
      });
    } on CameraException catch (e) {
      setState(() =>
          _cameraError = "Camera error: ${e.description ?? e.code}");
    } catch (_) {
      setState(() => _cameraError = "Camera error.");
    }
  }

  Future<void> _startStreamSafely() async {
    final cam = controller;
    if (cam == null || !cam.value.isInitialized || _isStreaming) return;
    try {
      await cam.startImageStream((image) {
        if (!_isDetecting) {
          _isDetecting = true;
          _processImage(image);
        }
      });
      _isStreaming = true;
    } catch (e) {
      debugPrint("Stream failed: $e");
    }
  }

  Future<void> _stopStreamSafely() async {
    final cam = controller;
    if (cam == null || !_isStreaming) return;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {} finally {
      _isStreaming = false;
    }
  }

  Future<void> _processImage(CameraImage image) async {
    final detector = _poseDetector;
    if (detector == null) {
      _isDetecting = false;
      return;
    }
    final result = _inputImageFromCameraImage(image);
    if (result == null) {
      _isDetecting = false;
      return;
    }
    try {
      final poses = await detector.processImage(result.inputImage);
      if (!mounted) return;
      if (poses.isNotEmpty) {
        _trackSquatImproved(poses.first);
        setState(() {
          _latestPose = poses.first;
          _imageSize = result.adjustedSize;
        });
      } else {
        if (_latestPose != null) setState(() => _latestPose = null);
      }
    } catch (_) {} finally {
      _isDetecting = false;
    }
  }

  // ---------- Squat Detection (PRESERVED) ----------
  double _calculateAngle(
      PoseLandmark first, PoseLandmark mid, PoseLandmark last) {
    double radians = math.atan2(last.y - mid.y, last.x - mid.x) -
        math.atan2(first.y - mid.y, first.x - mid.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  List<PoseLandmark>? _pickReliableSide(
    Pose pose,
    PoseLandmarkType leftA,
    PoseLandmarkType leftB,
    PoseLandmarkType leftC,
    PoseLandmarkType rightA,
    PoseLandmarkType rightB,
    PoseLandmarkType rightC,
  ) {
    final left = [
      pose.landmarks[leftA],
      pose.landmarks[leftB],
      pose.landmarks[leftC]
    ];
    final right = [
      pose.landmarks[rightA],
      pose.landmarks[rightB],
      pose.landmarks[rightC]
    ];
    double scoreOf(List<PoseLandmark?> pts) {
      if (pts.any((p) => p == null)) return -1;
      return pts.map((p) => p!.likelihood).reduce(math.min);
    }

    final leftScore = scoreOf(left);
    final rightScore = scoreOf(right);
    if (leftScore < 0.55 && rightScore < 0.55) return null;
    final chosen = leftScore >= rightScore ? left : right;
    return [chosen[0]!, chosen[1]!, chosen[2]!];
  }

  double _smooth(List<double> buffer, double newValue) {
    buffer.add(newValue);
    if (buffer.length > 4) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  void _trackSquatImproved(Pose pose) {
    final side = _pickReliableSide(
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.rightAnkle,
    );
    if (side == null) return;
    final angle =
        _smooth(_squatAngleBuffer, _calculateAngle(side[0], side[1], side[2]));
    if (angle < 100.0) {
      _squatState = "down";
    } else if (angle > 160.0 && _squatState == "down") {
      final now = DateTime.now();
      final canCount = _lastSquatTime == null ||
          now.difference(_lastSquatTime!) > const Duration(milliseconds: 500);
      _squatState = "up";
      if (canCount) {
        _lastSquatTime = now;
        _onSquatDetected();
        _addBonusTime(20);
      }
    }
  }

  void _onSquatDetected() {
    if (!mounted) return;
    setState(() {
      squatsCount++;
      points += (level == UserLevel.beginner)
          ? 10
          : (level == UserLevel.intermediate)
              ? 20
              : 30;
    });
    _updateStreak();
    _saveData();
  }

  // ---------- Pedometer for Walking Mode ----------
  void _startPedometer() {
    _accelSub = accelerometerEvents.listen((AccelerometerEvent event) {
      final magnitude = math.sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);
      final delta = magnitude - _lastMagnitude;
      _lastMagnitude = magnitude;
      if (delta > 15) {
        // step threshold
        _stepCount++;
        // reward for walking: same logic as squat
        if (_workoutMode != WorkoutMode.squatsOnly) {
          setState(() {
            points += (level == UserLevel.beginner)
                ? 5
                : (level == UserLevel.intermediate)
                    ? 10
                    : 15;
          });
          _updateStreak();
          _saveData();
          // add bonus time every 10 steps
          if (_stepCount % 10 == 0) {
            _addBonusTime(10);
          }
        }
      }
    });
  }

  // ---------- Streak ----------
  void _updateStreak() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_lastWorkoutDate != today) {
      final yesterday = DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10);
      setState(() {
        if (_lastWorkoutDate == yesterday) {
          _streak++;
        } else {
          _streak = 1;
        }
        _lastWorkoutDate = today;
      });
    }
  }

  // ---------- Onboarding Completion ----------
  void _completeOnboarding(int targetMinutes, double screenHours,
      String motivation, WorkoutMode mode, UserLevel userLevel) {
    setState(() {
      _dailyTargetScrollMinutes = targetMinutes;
      _dailyScreenHours = screenHours;
      _selectedMotivation = motivation;
      _workoutMode = mode;
      level = userLevel;
      _allowedScrollTime = targetMinutes * 60;
      _onboardingComplete = true;
    });
    _saveData();
  }

  // ---------- Admin ----------
  void _handleAdminTap() {
    _adminTapCount++;
    if (_adminTapCount >= 5) {
      setState(() {
        _isAdminVisible = true;
        _adminTapCount = 0;
      });
      _showErrorSnackBar("Admin panel unlocked.");
    }
  }

  // ---------- UI ----------
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    if (!_onboardingComplete) {
      return OnboardingFlow(onComplete: _completeOnboarding);
    }
    return Scaffold(
      body: IndexedStack(
        index: _selectedTab,
        children: [
          _buildHomeTab(),
          _buildAppLockTab(),
          _buildCreditsShopTab(),
          _buildAnalyticsTab(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: BoltColors.border, width: 1),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedTab,
          onTap: (index) => setState(() => _selectedTab = index),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.fitness_center_rounded),
              label: 'Workout',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.lock_rounded),
              label: 'App Lock',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.card_giftcard_rounded),
              label: 'Credits',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_rounded),
              label: 'Analytics',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    double progress = _allowedScrollTime / _maxScrollTime;
    bool isLow = _allowedScrollTime <= 30 && !_isAppBlocked;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BoltColors.bg, Color(0xFF15152A)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildTimeCard(progress, isLow),
            const SizedBox(height: 8),
            Expanded(flex: 5, child: _buildCameraArea()),
            const SizedBox(height: 8),
            Expanded(flex: 3, child: _buildStatsPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [BoltColors.neon, BoltColors.neon],
            ).createShader(bounds),
            child: const Text(
              'FITPAY',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 26,
                letterSpacing: 2,
                color: Colors.white,
              ),
            ),
          ),
          Row(
            children: [
              // Streak fire
              if (_streak > 0) ...[
                Icon(Icons.local_fire_department_rounded,
                    color: BoltColors.warning, size: 20),
                Text('$_streak',
                    style: const TextStyle(
                        color: BoltColors.warning, fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: BoltColors.surfaceLight,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BoltColors.neon.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.stars_rounded,
                        color: BoltColors.warning, size: 20),
                    const SizedBox(width: 4),
                    Text('$points',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimeCard(double progress, bool isLow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final glow = (isLow || _isAppBlocked) ? _pulseController.value : 0.0;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: BoltColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: (_isAppBlocked ? BoltColors.danger : BoltColors.neon)
                    .withOpacity(0.3 + glow * 0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isAppBlocked ? BoltColors.danger : BoltColors.neon)
                      .withOpacity(0.15 + glow * 0.15),
                  blurRadius: 18,
                  spreadRadius: 1,
                )
              ],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isAppBlocked
                              ? Icons.lock_clock_rounded
                              : Icons.timer_outlined,
                          color: _isAppBlocked
                              ? BoltColors.danger
                              : BoltColors.warning,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isAppBlocked
                              ? 'Time’s up! Exercise to unlock'
                              : 'Scroll Credits',
                          style:
                              const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                    Text(
                      '${_allowedScrollTime ~/ 60}m ${_allowedScrollTime % 60}s',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: _isAppBlocked
                            ? BoltColors.danger
                            : Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: TweenAnimationBuilder<double>(
                    tween:
                        Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 400),
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 10,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _isAppBlocked
                            ? BoltColors.danger
                            : BoltColors.success,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCameraArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ScaleTransition(
        scale: _repController,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: BoltColors.neon, width: 2.5),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x4D00F0FF),
                      blurRadius: 20,
                      spreadRadius: 2)
                ],
              ),
              child: _buildCameraContent(),
            ),
            if (_showSuccessFlash) ...[
              Container(
                decoration: BoxDecoration(
                  color: BoltColors.success.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              const Icon(Icons.check_circle_rounded,
                  color: BoltColors.success, size: 85),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCameraContent() {
    if (_cameraError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded,
                color: Colors.white38, size: 48),
            const SizedBox(height: 10),
            Text(_cameraError!,
                style: const TextStyle(color: Colors.white60)),
            TextButton(
              onPressed: () {
                setState(() => _cameraError = null);
                _initializeCamera();
              },
              child: const Text('Retry',
                  style: TextStyle(color: BoltColors.neon)),
            ),
          ],
        ),
      );
    }
    if (!_isCameraInitialized || controller == null) {
      return const Center(
          child: CircularProgressIndicator(color: BoltColors.neon));
    }
    return Transform(
      alignment: Alignment.center,
      transform: _isFrontCamera
          ? Matrix4.rotationY(math.pi)
          : Matrix4.identity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller!),
          if (_latestPose != null && _imageSize != null)
            CustomPaint(
                painter: NeonSkeletonPainter(_latestPose!, _imageSize!)),
        ],
      ),
    );
  }

  Widget _buildStatsPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black45, blurRadius: 15, offset: Offset(0, -5))
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatCard('Squats', squatsCount, BoltColors.neon,
                  Icons.accessibility_new_rounded),
              _buildStatCard('Steps', _stepCount, BoltColors.success,
                  Icons.directions_walk_rounded),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Level: ',
                  style:
                      TextStyle(color: Colors.white54, fontSize: 13)),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: BoltColors.surfaceLight,
                    borderRadius: BorderRadius.circular(15)),
                child: Row(
                  children: [
                    _buildLevelChip('Beginner', UserLevel.beginner),
                    _buildLevelChip('Intermediate', UserLevel.intermediate),
                    _buildLevelChip('Beast', UserLevel.advanced),
                  ],
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildStatCard(
      String title, int value, Color color, IconData icon) {
    return Container(
      width: 135,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: BoltColors.surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.4), width: 1.5),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(title,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 12)),
          Text('$value',
              style: TextStyle(
                  color: color, fontSize: 24, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _buildLevelChip(String label, UserLevel chipLevel) {
    bool isSelected = level == chipLevel;
    return ChoiceChip(
      label: Text(label,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => level = chipLevel);
          _saveData();
        }
      },
      selectedColor: BoltColors.neon.withOpacity(0.2),
      backgroundColor: Colors.transparent,
      labelStyle: TextStyle(
          color: isSelected ? BoltColors.neon : Colors.white60),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  // ---------- Tab 2: App Lock Manager ----------
  Widget _buildAppLockTab() {
    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('App Lock Manager',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 8),
              Text(
                'Block distracting apps when scroll credits run out.',
                style: TextStyle(color: Colors.white60, fontSize: 14),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView(
                  children: _appsToBlock.entries.map((entry) {
                    final data = entry.value;
                    return Card(
                      color: BoltColors.surface,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: SwitchListTile(
                        activeColor: BoltColors.neon,
                        secondary: Icon(data['icon'] as IconData,
                            color: BoltColors.neon),
                        title: Text(data['name'] as String,
                            style: const TextStyle(color: Colors.white)),
                        value: data['blocked'] as bool,
                        onChanged: (val) {
                          setState(() => data['blocked'] = val);
                          _saveData();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
              if (!_isBlockingServiceEnabled)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: BoltColors.warning,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _requestBlockingPermission,
                    icon: const Icon(Icons.security),
                    label: const Text('Grant Overlay Permission',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Tab 3: Credits & Pro Shop ----------
  Widget _buildCreditsShopTab() {
    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Credits & Pro Shop',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 20),
              // Redeem points
              Text('Your Points: $points',
                  style: const TextStyle(
                      color: BoltColors.warning,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              const Text('Redeem for Scroll Time',
                  style: TextStyle(
                      color: Colors.white, fontSize: 18)),
              const SizedBox(height: 12),
              _redeemCard(500, 5), // 500 pts = 5 min
              const SizedBox(height: 10),
              _redeemCard(1000, 12), // 1000 pts = 12 min
              const SizedBox(height: 10),
              _redeemCard(2000, 30), // 2000 pts = 30 min
              const SizedBox(height: 30),
              // Pro subscription
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E1E30), Color(0xFF161620)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: BoltColors.neon.withOpacity(0.3)),
                  boxShadow: [
                    BoxShadow(
                        color: BoltColors.neon.withOpacity(0.1),
                        blurRadius: 20,
                        spreadRadius: 2)
                  ],
                ),
                child: Column(
                  children: [
                    const Icon(Icons.diamond_rounded,
                        color: BoltColors.neon, size: 40),
                    const SizedBox(height: 8),
                    const Text('FitPay Pro',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text(
                        'Unlimited blocks, leaderboards, zero ads',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Colors.white70, fontSize: 14)),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _proPlan('Monthly', '\$4.99', 'month'),
                        _proPlan('Annual', '\$29.99', 'year',
                            bestValue: true),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: BoltColors.neon,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: () {
                          // Simulate starting trial
                          _showErrorSnackBar(
                              '7-Day Free Trial activated (mock)');
                        },
                        icon: const Icon(Icons.local_fire_department),
                        label: const Text('Start 7-Day Free Trial',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _redeemCard(int pointsCost, int minutes) {
    final canAfford = points >= pointsCost;
    return Card(
      color: BoltColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
              color: canAfford
                  ? BoltColors.neon.withOpacity(0.4)
                  : Colors.white10)),
      child: ListTile(
        leading: Icon(Icons.timer_rounded,
            color: canAfford ? BoltColors.neon : Colors.white38),
        title: Text('$minutes minutes scroll time',
            style: TextStyle(
                color: canAfford ? Colors.white : Colors.white38)),
        subtitle: Text('Cost: $pointsCost points',
            style: const TextStyle(color: Colors.white54)),
        trailing: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor:
                canAfford ? BoltColors.neon : Colors.white12,
            foregroundColor: canAfford ? Colors.black : Colors.white38,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: canAfford
              ? () {
                  setState(() {
                    points -= pointsCost;
                    _allowedScrollTime += minutes * 60;
                    _saveData();
                  });
                }
              : null,
          child: const Text('Redeem'),
        ),
      ),
    );
  }

  Widget _proPlan(String name, String price, String period,
      {bool bestValue = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bestValue ? BoltColors.neon.withOpacity(0.1) : Colors.white5,
        borderRadius: BorderRadius.circular(16),
        border: bestValue
            ? Border.all(color: BoltColors.neon, width: 1.5)
            : Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          if (bestValue)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: BoltColors.neon,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('BEST VALUE',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ),
          Text(name,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          Text(price,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          Text('/$period',
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ],
      ),
    );
  }

  // ---------- Tab 4: Analytics & Admin ----------
  Widget _buildAnalyticsTab() {
    final wastedYears = _dailyScreenHours * 3650 / 24;
    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Analytics & Squad',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 20),
              // Reality Check
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: BoltColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BoltColors.danger.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: BoltColors.danger, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('10-Year Reality Check',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                          Text(
                              'At ${_dailyScreenHours.toStringAsFixed(1)}h/day, you will waste ${wastedYears.toStringAsFixed(1)} YEARS of your life on your phone.',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Progress charts (mock)
              _buildProgressCard('Today', Icons.today_rounded,
                  '${squatsCount} squats, ${_stepCount} steps'),
              _buildProgressCard('This Week', Icons.calendar_view_week_rounded,
                  '${(squatsCount * 7)} squats (est), ${(_stepCount * 7)} steps'),
              _buildProgressCard('Saved Time',
                  Icons.access_time_rounded,
                  '${(_allowedScrollTime ~/ 60)} minutes'),
              const SizedBox(height: 24),
              // Squad leaderboard (mock)
              const Text('Squad Leaderboard',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _leaderboardTile('1', 'You', points),
              _leaderboardTile('2', 'FitFighter92', 8500),
              _leaderboardTile('3', 'SquatQueen', 7200),
              const SizedBox(height: 30),
              // Admin Panel trigger
              GestureDetector(
                onTap: _handleAdminTap,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: BoltColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.settings_applications,
                          color: Colors.white38),
                      const SizedBox(width: 12),
                      const Text('App Version 1.0.0',
                          style: TextStyle(color: Colors.white54)),
                      const Spacer(),
                      if (_isAdminVisible)
                        const Icon(Icons.shield_rounded,
                            color: BoltColors.neon),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_isAdminVisible) _buildAdminPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressCard(String title, IconData icon, String value) {
    return Card(
      color: BoltColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: BoltColors.neon),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(value,
            style: const TextStyle(color: Colors.white70, fontSize: 16)),
      ),
    );
  }

  Widget _leaderboardTile(String rank, String name, int score) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: rank == '1' ? BoltColors.warning : BoltColors.surfaceLight,
        child: Text(rank,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      title: Text(name, style: const TextStyle(color: Colors.white)),
      trailing: Text('$score pts',
          style: const TextStyle(
              color: BoltColors.warning, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildAdminPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BoltColors.neon.withOpacity(0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('👑 Owner Dashboard',
              style: TextStyle(
                  color: BoltColors.neon,
                  fontWeight: FontWeight.bold,
                  fontSize: 18)),
          const Divider(color: Colors.white10),
          const SizedBox(height: 8),
          _adminAction('Test Overlay Permission', Icons.security,
              _requestBlockingPermission),
          _adminAction('Add 1000 Credits', Icons.add_circle, () {
            setState(() => points += 1000);
            _saveData();
          }),
          _adminAction('Toggle Pro Status', Icons.diamond, () {
            // mock Pro toggle
            _showErrorSnackBar("Pro status toggled (mock)");
          }),
          const SizedBox(height: 12),
          const Text('Simulated Metrics',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          const Text('• Total Users: 128',
              style: TextStyle(color: Colors.white54)),
          const Text('• Active Now: 12',
              style: TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }

  Widget _adminAction(String label, IconData icon, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: BoltColors.neon),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.arrow_forward_ios,
          size: 16, color: Colors.white38),
      onTap: onTap,
    );
  }

  // ---------- Onboarding Flow ----------
  // The _inputImageFromCameraImage helper (preserved)
  _InputImageResult? _inputImageFromCameraImage(CameraImage image) {
    final cam = controller;
    if (cam == null) return null;
    final camera = cam.description;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[cam.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation =
            (camera.sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (camera.sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    final rawSize = Size(image.width.toDouble(), image.height.toDouble());
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: rawSize,
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
    final isRotated90or270 = rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final adjustedSize =
        isRotated90or270 ? Size(rawSize.height, rawSize.width) : rawSize;
    return _InputImageResult(
        inputImage: inputImage, adjustedSize: adjustedSize);
  }

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
}

// ---------- Onboarding Flow ----------
class OnboardingFlow extends StatefulWidget {
  final Function(int targetMinutes, double screenHours, String motivation,
      WorkoutMode mode, UserLevel level) onComplete;
  const OnboardingFlow({super.key, required this.onComplete});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  // answers
  double _screenHours = 6.0;
  int _targetMinutes = 30;
  String _motivation = 'Reduce screen time';
  WorkoutMode _mode = WorkoutMode.both;
  UserLevel _level = UserLevel.beginner;
  String _source = 'Social Media';

  void _next() {
    if (_currentStep < 5) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    } else {
      widget.onComplete(_targetMinutes, _screenHours, _motivation, _mode, _level);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BoltColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // progress dots
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (index) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentStep == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentStep == index
                          ? BoltColors.neon
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentStep = i),
                children: [
                  _step1(), _step2(), _step3(), _step4(), _step5(), _step6(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BoltColors.neon,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _next,
                  child: Text(
                    _currentStep == 5 ? 'Start Fitpay' : 'Next',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step1() {
    final yearsWasted = _screenHours * 3650 / 24;
    return OnboardingStep(
      title: 'Daily Screen Time',
      child: Column(
        children: [
          const Text('How many hours do you spend on your phone daily?',
              style: TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center),
          Slider(
            value: _screenHours,
            min: 1,
            max: 16,
            divisions: 15,
            activeColor: BoltColors.neon,
            onChanged: (v) => setState(() => _screenHours = v),
          ),
          Text('${_screenHours.toStringAsFixed(1)} hours',
              style: const TextStyle(
                  color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: BoltColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BoltColors.danger.withOpacity(0.5)),
            ),
            child: Text(
              'At this rate, you will waste ${yearsWasted.toStringAsFixed(1)} YEARS of your life on your phone in the next 10 years!',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: BoltColors.danger,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step2() {
    return OnboardingStep(
      title: 'Target Scroll Time',
      child: Column(
        children: [
          const Text('How many minutes of unlocked phone time do you want daily?',
              style: TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center),
          Slider(
            value: _targetMinutes.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            activeColor: BoltColors.neon,
            onChanged: (v) => setState(() => _targetMinutes = v.round()),
          ),
          Text('$_targetMinutes minutes',
              style: const TextStyle(
                  color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _step3() {
    return OnboardingStep(
      title: 'Your Motivation',
      child: Column(
        children: [
          const Text('Why do you want to train with Fitpay?',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 12),
          ...['Reduce screen time', 'Lose weight', 'Build strength', 'Stay active']
              .map((m) => ChoiceChip(
                    label: Text(m),
                    selected: _motivation == m,
                    onSelected: (_) => setState(() => _motivation = m),
                    selectedColor: BoltColors.neon.withOpacity(0.2),
                    backgroundColor: BoltColors.surface,
                    labelStyle: TextStyle(
                        color: _motivation == m
                            ? BoltColors.neon
                            : Colors.white70),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ))
              .toList(),
        ],
      ),
    );
  }

  Widget _step4() {
    return OnboardingStep(
      title: 'Workout Preference',
      child: Column(
        children: [
          const Text('Select your preferred exercise mode:',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 12),
          ...['Walking Only', 'Squats Only', 'Both']
              .asMap()
              .entries
              .map((e) => ChoiceChip(
                    label: Text(e.value),
                    selected: _mode.index == e.key,
                    onSelected: (_) =>
                        setState(() => _mode = WorkoutMode.values[e.key]),
                    selectedColor: BoltColors.neon.withOpacity(0.2),
                    backgroundColor: BoltColors.surface,
                    labelStyle: TextStyle(
                        color: _mode.index == e.key
                            ? BoltColors.neon
                            : Colors.white70),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ))
              .toList(),
        ],
      ),
    );
  }

  Widget _step5() {
    return OnboardingStep(
      title: 'Fitness Level',
      child: Column(
        children: [
          const Text('Choose your capacity:',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 12),
          ...UserLevel.values
              .map((l) => ChoiceChip(
                    label: Text(l == UserLevel.beginner
                        ? 'Beginner (50m/10 squats = 1 min)'
                        : l == UserLevel.intermediate
                            ? 'Intermediate (75m/15 squats = 1 min)'
                            : 'Beast Mode (100m/20 squats = 1 min)'),
                    selected: _level == l,
                    onSelected: (_) => setState(() => _level = l),
                    selectedColor: BoltColors.neon.withOpacity(0.2),
                    backgroundColor: BoltColors.surface,
                    labelStyle: TextStyle(
                        color: _level == l ? BoltColors.neon : Colors.white70),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ))
              .toList(),
        ],
      ),
    );
  }

  Widget _step6() {
    return OnboardingStep(
      title: 'How did you find us?',
      child: Column(
        children: [
          const Text('Select one:',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 12),
          ...['Social Media', 'Friend', 'App Store', 'Other']
              .map((s) => ChoiceChip(
                    label: Text(s),
                    selected: _source == s,
                    onSelected: (_) => setState(() => _source = s),
                    selectedColor: BoltColors.neon.withOpacity(0.2),
                    backgroundColor: BoltColors.surface,
                    labelStyle: TextStyle(
                        color: _source == s ? BoltColors.neon : Colors.white70),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ))
              .toList(),
        ],
      ),
    );
  }
}

class OnboardingStep extends StatelessWidget {
  final String title;
  final Widget child;
  const OnboardingStep({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 24),
          child,
        ],
      ),
    );
  }
}

// ---------- Preserved Helper Classes ----------
class _InputImageResult {
  final InputImage inputImage;
  final Size adjustedSize;
  const _InputImageResult({required this.inputImage, required this.adjustedSize});
}

// Neon skeleton painter (unchanged logic, adapted colors)
class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  static const double _minLikelihoodToDraw = 0.5;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width == 0 || imageSize.height == 0) return;

    final linePaint = Paint()
      ..color = const Color(0xff00f0ff)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final glowPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.3)
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final dotGlowPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.5)
      ..style = PaintingStyle.fill;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset? getPoint(PoseLandmarkType type) {
      final landmark = pose.landmarks[type];
      if (landmark == null || landmark.likelihood < _minLikelihoodToDraw)
        return null;
      return Offset(landmark.x * scaleX, landmark.y * scaleY);
    }

    void drawBone(PoseLandmarkType type1, PoseLandmarkType type2) {
      final p1 = getPoint(type1);
      final p2 = getPoint(type2);
      if (p1 != null && p2 != null) {
        canvas.drawLine(p1, p2, glowPaint);
        canvas.drawLine(p1, p2, linePaint);
      }
    }

    drawBone(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
    drawBone(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    drawBone(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    drawBone(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    drawBone(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);

    drawBone(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
    drawBone(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
    drawBone(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);

    drawBone(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    drawBone(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    drawBone(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    drawBone(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);

    for (final landmark in pose.landmarks.values) {
      if (landmark.likelihood >= _minLikelihoodToDraw) {
        final point = Offset(landmark.x * scaleX, landmark.y * scaleY);
        canvas.drawCircle(point, 7.0, dotGlowPaint);
        canvas.drawCircle(point, 3.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) {
    return oldDelegate.pose != pose || oldDelegate.imageSize != imageSize;
  }
}
