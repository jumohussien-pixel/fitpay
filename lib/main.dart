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
    debugPrint("Camera initialization error: $e");
  }
  runApp(const FitPayApp());
}

// ==========================================
// BOLT HIGH-END DARK MODERN PALETTE & STYLES
// ==========================================
class BoltColors {
  static const Color bg = Color(0xFF090A0F);
  static const Color surface = Color(0xFF12141D);
  static const Color surfaceLight = Color(0xFF1B1E2E);
  static const Color surfaceBorder = Color(0xFF2A2E45);
  
  static const Color neonCyan = Color(0xFF00F0FF);
  static const Color neonGreen = Color(0xFF00FF88);
  static const Color electricOrange = Color(0xFFFF6B00);
  static const Color warning = Color(0xFFFFC107);
  static const Color danger = Color(0xFFFF2A55);
  
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFA0A5C0);
}

// ==========================================
// ENUMS & MODELS
// ==========================================
enum UserLevel { beginner, intermediate, beast }
enum WorkoutMode { squatsOnly, walkingOnly, both }

class AppInfo {
  final String packageName;
  final String appName;
  bool isBlocked;
  final IconData icon;

  AppInfo({
    required this.packageName,
    required this.appName,
    this.isBlocked = false,
    this.icon = Icons.android_rounded,
  });
}

// ==========================================
// MAIN APP ROOT
// ==========================================
class FitPayApp extends StatelessWidget {
  const FitPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitPay',
      theme: ThemeData(
        scaffoldBackgroundColor: BoltColors.bg,
        brightness: Brightness.dark,
        primaryColor: BoltColors.neonCyan,
        colorScheme: const ColorScheme.dark(
          primary: BoltColors.neonCyan,
          secondary: BoltColors.electricOrange,
          surface: BoltColors.surface,
        ),
        fontFamily: 'Roboto',
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: BoltColors.surface,
          selectedItemColor: BoltColors.neonCyan,
          unselectedItemColor: BoltColors.textSecondary,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ==========================================
// MAIN SCREEN WITH TAB NAVIGATION
// ==========================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const platform = MethodChannel('com.fitpay.app/overlay');

  // Camera & ML Kit
  CameraController? controller;
  PoseDetector? _poseDetector;
  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String? _cameraError;
  Pose? _latestPose;
  Size? _imageSize;
  bool _isFrontCamera = true;

  // Fitness State & Credits
  int credits = 0;
  int squatsCount = 0;
  int stepCount = 0;
  double distanceWalkedMeters = 0.0;
  UserLevel level = UserLevel.beginner;
  WorkoutMode workoutMode = WorkoutMode.both;
  
  String _squatState = "up";
  DateTime? _lastSquatTime;
  final List<double> _squatAngleBuffer = [];

  // Time & Background Tracking
  int _allowedScrollTimeSeconds = 0; // Purchased scroll allowance
  DateTime? _backgroundStartTime;
  bool _isAppBlocked = false;
  bool _showSuccessFlash = false;
  
  // Pro Subscription Tier
  bool isProUser = false;

  // App Lock Manager State
  bool _isBlockingServiceEnabled = false;
  List<AppInfo> _installedApps = [];

  // Gamification & Preferences
  int _streak = 0;
  String _lastWorkoutDate = '';
  String _selectedMotivation = 'Reduce screen time';
  int _dailyTargetScrollMinutes = 30;
  double _dailyScreenHours = 6.0;

  // Onboarding Status
  bool _onboardingComplete = false;

  // Admin Controls
  bool _isAdminVisible = false;
  int _adminTapCount = 0;

  // Animations & Sensors
  late final AnimationController _pulseController;
  late final AnimationController _repController;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _lastMagnitude = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _repController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      lowerBound: 0.95,
      upperBound: 1.12,
      value: 1.0,
    );

    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.accurate,
        mode: PoseDetectionMode.stream,
      ),
    );

    _loadDefaultAppsList();
    _loadData();
    _checkPermissions();
    _initializeCamera();
    _startPedometerAndGPS();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _repController.dispose();
    _stopStreamSafely();
    controller?.dispose();
    _poseDetector?.close();
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // User left Fitpay -> Start recording time spent outside!
      _backgroundStartTime = DateTime.now();
      _stopStreamSafely();
    } else if (state == AppLifecycleState.resumed) {
      // User returned to Fitpay -> Calculate elapsed time outside
      if (_backgroundStartTime != null) {
        final elapsedSeconds = DateTime.now().difference(_backgroundStartTime!).inSeconds;
        _backgroundStartTime = null;

        if (_allowedScrollTimeSeconds > 0) {
          setState(() {
            _allowedScrollTimeSeconds = math.max(0, _allowedScrollTimeSeconds - elapsedSeconds);
            if (_allowedScrollTimeSeconds == 0) {
              _isAppBlocked = true;
              _forceCloseBackgroundApps();
            }
          });
          _saveData();
        }
      }

      if (_isAppBlocked) _forceCloseBackgroundApps();
      if (_isCameraInitialized && !_isStreaming) _startStreamSafely();
    }
  }

  // ---------- APP LIST & PERMISSIONS ----------
  void _loadDefaultAppsList() {
    _installedApps = [
      AppInfo(packageName: 'com.zhiliaoapp.musically', appName: 'TikTok', isBlocked: true, icon: Icons.video_library_rounded),
      AppInfo(packageName: 'com.instagram.android', appName: 'Instagram', isBlocked: true, icon: Icons.camera_alt_rounded),
      AppInfo(packageName: 'com.google.android.youtube', appName: 'YouTube', isBlocked: false, icon: Icons.play_circle_fill_rounded),
      AppInfo(packageName: 'com.facebook.katana', appName: 'Facebook', isBlocked: false, icon: Icons.facebook_rounded),
      AppInfo(packageName: 'com.twitter.android', appName: 'X / Twitter', isBlocked: false, icon: Icons.alternate_email_rounded),
      AppInfo(packageName: 'com.snapchat.android', appName: 'Snapchat', isBlocked: false, icon: Icons.snapchat_rounded),
      AppInfo(packageName: 'com.reddit.frontpage', appName: 'Reddit', isBlocked: false, icon: Icons.forum_rounded),
    ];
  }

  Future<void> _checkPermissions() async {
    try {
      final bool hasPermission = await platform.invokeMethod('checkPermissions') ?? false;
      setState(() => _isBlockingServiceEnabled = hasPermission);
      _fetchInstalledAppsFromNative();
    } catch (_) {}
  }

  Future<void> _fetchInstalledAppsFromNative() async {
    try {
      final List<dynamic>? apps = await platform.invokeMethod('getInstalledApps');
      if (apps != null && apps.isNotEmpty) {
        setState(() {
          _installedApps = apps.map((a) {
            return AppInfo(
              packageName: a['packageName'] ?? '',
              appName: a['appName'] ?? 'App',
              isBlocked: false,
            );
          }).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _requestBlockingPermission() async {
    try {
      await platform.invokeMethod('requestPermissions');
      _checkPermissions();
    } catch (e) {
      _showSnackBar("Open system settings to grant usage & overlay access.");
    }
  }

  Future<void> _forceCloseBackgroundApps() async {
    try {
      final blockedPackages = _installedApps.where((a) => a.isBlocked).map((a) => a.packageName).toList();
      await platform.invokeMethod('blockApps', {'packages': blockedPackages});
    } catch (_) {}
  }

  // ---------- DATA PERSISTENCE ----------
  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      credits = prefs.getInt('credits') ?? 0;
      squatsCount = prefs.getInt('squatsCount') ?? 0;
      stepCount = prefs.getInt('stepCount') ?? 0;
      distanceWalkedMeters = prefs.getDouble('distanceWalkedMeters') ?? 0.0;
      
      level = UserLevel.values[(prefs.getInt('level') ?? 0).clamp(0, 2)];
      workoutMode = WorkoutMode.values[(prefs.getInt('workout_mode') ?? 2).clamp(0, 2)];
      
      _allowedScrollTimeSeconds = prefs.getInt('scroll_time_seconds') ?? 0;
      _streak = prefs.getInt('streak') ?? 0;
      _lastWorkoutDate = prefs.getString('last_workout_date') ?? '';
      _dailyTargetScrollMinutes = prefs.getInt('daily_target_minutes') ?? 30;
      _dailyScreenHours = prefs.getDouble('daily_screen_hours') ?? 6.0;
      _selectedMotivation = prefs.getString('motivation') ?? 'Reduce screen time';
      _onboardingComplete = prefs.getBool('onboarding_done') ?? false;
      isProUser = prefs.getBool('is_pro_user') ?? false;

      for (var app in _installedApps) {
        if (prefs.containsKey('block_${app.packageName}')) {
          app.isBlocked = prefs.getBool('block_${app.packageName}') ?? false;
        }
      }
    });
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('credits', credits);
    await prefs.setInt('squatsCount', squatsCount);
    await prefs.setInt('stepCount', stepCount);
    await prefs.setDouble('distanceWalkedMeters', distanceWalkedMeters);
    await prefs.setInt('level', level.index);
    await prefs.setInt('workout_mode', workoutMode.index);
    await prefs.setInt('scroll_time_seconds', _allowedScrollTimeSeconds);
    await prefs.setInt('streak', _streak);
    await prefs.setString('last_workout_date', _lastWorkoutDate);
    await prefs.setInt('daily_target_minutes', _dailyTargetScrollMinutes);
    await prefs.setDouble('daily_screen_hours', _dailyScreenHours);
    await prefs.setString('motivation', _selectedMotivation);
    await prefs.setBool('onboarding_done', _onboardingComplete);
    await prefs.setBool('is_pro_user', isProUser);

    for (var app in _installedApps) {
      await prefs.setBool('block_${app.packageName}', app.isBlocked);
    }
  }

  // ---------- CAMERA & POSE DETECTOR ----------
  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = "No camera available.");
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
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await controller!.initialize();
      if (!mounted) return;
      await _startStreamSafely();
      setState(() {
        _isCameraInitialized = true;
        _cameraError = null;
      });
    } catch (e) {
      setState(() => _cameraError = "Camera initialization failed.");
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
    } catch (_) {}
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

  // ---------- CORE SQUAT RECOGNITION ----------
  double _calculateAngle(PoseLandmark first, PoseLandmark mid, PoseLandmark last) {
    double radians = math.atan2(last.y - mid.y, last.x - mid.x) -
        math.atan2(first.y - mid.y, first.x - mid.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  List<PoseLandmark>? _pickReliableSide(Pose pose) {
    final left = [pose.landmarks[PoseLandmarkType.leftHip], pose.landmarks[PoseLandmarkType.leftKnee], pose.landmarks[PoseLandmarkType.leftAnkle]];
    final right = [pose.landmarks[PoseLandmarkType.rightHip], pose.landmarks[PoseLandmarkType.rightKnee], pose.landmarks[PoseLandmarkType.rightAnkle]];

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
    if (workoutMode == WorkoutMode.walkingOnly) return;

    final side = _pickReliableSide(pose);
    if (side == null) return;
    
    final angle = _smooth(_squatAngleBuffer, _calculateAngle(side[0], side[1], side[2]));
    
    if (angle < 100.0) {
      _squatState = "down";
    } else if (angle > 160.0 && _squatState == "down") {
      final now = DateTime.now();
      final canCount = _lastSquatTime == null || now.difference(_lastSquatTime!) > const Duration(milliseconds: 500);
      _squatState = "up";
      if (canCount) {
        _lastSquatTime = now;
        _onSquatCompleted();
      }
    }
  }

  void _onSquatCompleted() {
    if (!mounted) return;

    // Credit calculation rules based on Level:
    // Beginner: 1 Squat = 200 Credits
    // Intermediate: 1 Squat = 100 Credits
    // Beast: 1 Squat = 50 Credits (2 Squats = 100 Credits)
    int awardedCredits = (level == UserLevel.beginner)
        ? 200
        : (level == UserLevel.intermediate)
            ? 100
            : 50;

    setState(() {
      squatsCount++;
      credits += awardedCredits;
      _showSuccessFlash = true;
    });

    HapticFeedback.mediumImpact();
    _repController.forward().then((_) {
      if (mounted) _repController.reverse();
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });

    _updateStreak();
    _saveData();
  }

  // ---------- WALKING & SENSOR LOGIC ----------
  void _startPedometerAndGPS() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (workoutMode == WorkoutMode.squatsOnly) return;

      final magnitude = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final delta = magnitude - _lastMagnitude;
      _lastMagnitude = magnitude;

      if (delta > 14.5) {
        _stepCount++;
        distanceWalkedMeters += 0.75; // Average step length 0.75m

        // Reward every 100 meters walked
        if (distanceWalkedMeters >= 100.0) {
          int distanceMultiplier = (distanceWalkedMeters ~/ 100);
          distanceWalkedMeters %= 100.0;

          int walkingCreditsPer100m = (level == UserLevel.beginner)
              ? 100
              : (level == UserLevel.intermediate)
                  ? 50
                  : 25;

          setState(() {
            stepCount = _stepCount;
            credits += (walkingCreditsPer100m * distanceMultiplier);
          });
          _updateStreak();
          _saveData();
        }
      }
    });
  }

  // ---------- STREAK & DATA ----------
  void _updateStreak() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_lastWorkoutDate != today) {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      setState(() {
        _streak = (_lastWorkoutDate == yesterday) ? _streak + 1 : 1;
        _lastWorkoutDate = today;
      });
    }
  }

  void _completeOnboarding(int targetMinutes, double screenHours, String motivation, WorkoutMode mode, UserLevel userLevel) {
    setState(() {
      _dailyTargetScrollMinutes = targetMinutes;
      _dailyScreenHours = screenHours;
      _selectedMotivation = motivation;
      workoutMode = mode;
      level = userLevel;
      _onboardingComplete = true;
    });
    _saveData();
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? BoltColors.danger : BoltColors.neonCyan,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  // ---------- UI TAB BUILDERS ----------
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
          _buildHomeWorkoutTab(),
          _buildAppLockTab(),
          _buildCreditsShopTab(),
          _buildAnalyticsTab(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: BoltColors.surfaceBorder, width: 1)),
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
              icon: Icon(Icons.lock_outline_rounded),
              label: 'App Lock',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.shopping_bag_outlined),
              label: 'Credits Store',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.analytics_outlined),
              label: 'Analytics',
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------
  // TAB 1: WORKOUT & DETECTOR
  // ------------------------------------------
  Widget _buildHomeWorkoutTab() {
    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(),
            _buildPurchasedTimeBar(),
            const SizedBox(height: 8),
            Expanded(flex: 5, child: _buildCameraContainer()),
            const SizedBox(height: 8),
            Expanded(flex: 3, child: _buildStatsDashboard()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 38,
                height: 38,
                child: FitPayAppIconGraphic(),
              ),
              const SizedBox(width: 10),
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [BoltColors.neonCyan, Colors.white],
                ).createShader(bounds),
                child: const Text(
                  'FITPAY',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24, letterSpacing: 2, color: Colors.white),
                ),
              ),
            ],
          ),
          Row(
            children: [
              if (_streak > 0) ...[
                const Icon(Icons.local_fire_department_rounded, color: BoltColors.electricOrange, size: 22),
                const SizedBox(width: 2),
                Text('$_streak', style: const TextStyle(color: BoltColors.electricOrange, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(width: 12),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: BoltColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BoltColors.warning.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.monetization_on_rounded, color: BoltColors.warning, size: 18),
                    const SizedBox(width: 6),
                    Text('$credits C', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPurchasedTimeBar() {
    final mins = _allowedScrollTimeSeconds ~/ 60;
    final secs = _allowedScrollTimeSeconds % 60;
    final bool hasTime = _allowedScrollTimeSeconds > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BoltColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: hasTime ? BoltColors.neonGreen.withOpacity(0.4) : BoltColors.danger.withOpacity(0.4),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  hasTime ? Icons.hourglass_top_rounded : Icons.lock_clock_rounded,
                  color: hasTime ? BoltColors.neonGreen : BoltColors.danger,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Available Scroll Allowance', style: TextStyle(color: BoltColors.textSecondary, fontSize: 11)),
                    Text(
                      hasTime ? '$mins mins $secs secs left' : 'Time Exhausted - Earn Credits!',
                      style: TextStyle(color: hasTime ? Colors.white : BoltColors.danger, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: BoltColors.surfaceLight,
                foregroundColor: BoltColors.neonCyan,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => setState(() => _selectedTab = 2), // Go to Store
              child: const Text('Store', style: TextStyle(fontWeight: FontWeight.bold)),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildCameraContainer() {
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
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: BoltColors.neonCyan, width: 2),
                boxShadow: [
                  BoxShadow(color: BoltColors.neonCyan.withOpacity(0.2), blurRadius: 15, spreadRadius: 1)
                ],
              ),
              child: _buildCameraPreviewContent(),
            ),
            if (_showSuccessFlash) ...[
              Container(
                decoration: BoxDecoration(
                  color: BoltColors.neonGreen.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              const Icon(Icons.check_circle_rounded, color: BoltColors.neonGreen, size: 90),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreviewContent() {
    if (_cameraError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded, color: BoltColors.textSecondary, size: 48),
            const SizedBox(height: 8),
            Text(_cameraError!, style: const TextStyle(color: BoltColors.textSecondary)),
            TextButton(
              onPressed: () {
                setState(() => _cameraError = null);
                _initializeCamera();
              },
              child: const Text('Retry', style: TextStyle(color: BoltColors.neonCyan)),
            ),
          ],
        ),
      );
    }
    if (!_isCameraInitialized || controller == null) {
      return const Center(child: CircularProgressIndicator(color: BoltColors.neonCyan));
    }
    return Transform(
      alignment: Alignment.center,
      transform: _isFrontCamera ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller!),
          if (_latestPose != null && _imageSize != null)
            CustomPaint(painter: NeonSkeletonPainter(_latestPose!, _imageSize!)),
        ],
      ),
    );
  }

  Widget _buildStatsDashboard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _statCard('Squats', '$squatsCount', BoltColors.neonCyan, Icons.accessibility_new_rounded),
              _statCard('Steps', '$_stepCount', BoltColors.neonGreen, Icons.directions_walk_rounded),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Difficulty: ', style: TextStyle(color: BoltColors.textSecondary, fontSize: 13)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: BoltColors.surfaceLight, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    _levelChoiceChip('Beginner', UserLevel.beginner),
                    _levelChoiceChip('Pro', UserLevel.intermediate),
                    _levelChoiceChip('Beast', UserLevel.beast),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value, Color color, IconData icon) {
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: BoltColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 2),
          Text(title, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 11)),
          Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _levelChoiceChip(String label, UserLevel chipLevel) {
    bool isSelected = level == chipLevel;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => level = chipLevel);
          _saveData();
        }
      },
      selectedColor: BoltColors.neonCyan.withOpacity(0.2),
      backgroundColor: Colors.transparent,
      labelStyle: TextStyle(color: isSelected ? BoltColors.neonCyan : BoltColors.textSecondary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  // ------------------------------------------
  // TAB 2: APP LOCK MANAGER
  // ------------------------------------------
  Widget _buildAppLockTab() {
    int currentlyBlockedCount = _installedApps.where((a) => a.isBlocked).length;

    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('App Lock Manager', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isProUser ? BoltColors.electricOrange.withOpacity(0.2) : BoltColors.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isProUser ? BoltColors.electricOrange : BoltColors.surfaceBorder),
                    ),
                    child: Text(
                      isProUser ? 'PRO UNLIMITED' : 'FREE: $currentlyBlockedCount/3',
                      style: TextStyle(
                        color: isProUser ? BoltColors.electricOrange : BoltColors.neonCyan,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  )
                ],
              ),
              const SizedBox(height: 6),
              const Text('Select distractor apps to block when scroll allowance drops to 0.', style: TextStyle(color: BoltColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: _installedApps.length,
                  itemBuilder: (context, index) {
                    final app = _installedApps[index];
                    return Card(
                      color: BoltColors.surface,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: app.isBlocked ? BoltColors.neonCyan.withOpacity(0.5) : BoltColors.surfaceBorder),
                      ),
                      child: SwitchListTile(
                        activeColor: BoltColors.neonCyan,
                        secondary: Icon(app.icon, color: app.isBlocked ? BoltColors.neonCyan : BoltColors.textSecondary),
                        title: Text(app.appName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text(app.packageName, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 10)),
                        value: app.isBlocked,
                        onChanged: (val) {
                          if (val && !isProUser && currentlyBlockedCount >= 3) {
                            _showProUpgradeModal();
                          } else {
                            setState(() => app.isBlocked = val);
                            _saveData();
                          }
                        },
                      ),
                    );
                  },
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _requestBlockingPermission,
                    icon: const Icon(Icons.security_rounded),
                    label: const Text('Enable Overlay & Service Permission', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showProUpgradeModal() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BoltColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: BoltColors.electricOrange)),
        title: const Row(
          children: [
            Icon(Icons.diamond_rounded, color: BoltColors.electricOrange),
            SizedBox(width: 8),
            Text('Free Tier Limit Reached', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: const Text(
          'Free Tier allows locking up to 3 apps. Upgrade to FitPay Pro to lock unlimited apps and unlock exclusive store discounts!',
          style: TextStyle(color: BoltColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: BoltColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: BoltColors.electricOrange, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              setState(() => _selectedTab = 2); // Store tab
            },
            child: const Text('Upgrade to Pro', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------
  // TAB 3: CREDITS STORE & SPECIAL OFFERS
  // ------------------------------------------
  Widget _buildCreditsShopTab() {
    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Credits Store', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 4),
              Text('Available Balance: $credits Credits', style: const TextStyle(color: BoltColors.warning, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),

              // SPECIAL OFFERS SECTION
              const Row(
                children: [
                  Icon(Icons.local_offer_rounded, color: BoltColors.electricOrange, size: 20),
                  SizedBox(width: 8),
                  Text('🔥 Special Limited-Time Offers', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 10),
              _buildSpecialOfferCard('Flash Saver', '15 Minutes Scroll Time', 1200, 1500, 15),
              const SizedBox(height: 8),
              _buildSpecialOfferCard('Weekend Power Pass', '60 Minutes Scroll Time', 4000, 6000, 60),

              const SizedBox(height: 24),
              const Text('Standard Conversions (100 Credits = 1 Min)', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              _buildStandardRedeemTile(100, 1),
              _buildStandardRedeemTile(500, 5),
              _buildStandardRedeemTile(1000, 10),

              const SizedBox(height: 30),
              // PRO TIER BANNER
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF231911), Color(0xFF151722)]),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BoltColors.electricOrange.withOpacity(0.5)),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.workspace_premium_rounded, color: BoltColors.electricOrange, size: 40),
                    const SizedBox(height: 6),
                    const Text('FitPay Pro Subscription', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('Unlimited app blocking, zero ads, priority AI tracking', textAlign: TextAlign.center, style: TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: BoltColors.electricOrange,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          setState(() => isProUser = !isProUser);
                          _saveData();
                          _showSnackBar(isProUser ? 'Upgraded to FitPay Pro!' : 'Downgraded to Free Tier');
                        },
                        child: Text(isProUser ? 'Cancel Pro Subscription' : 'Upgrade to Pro - \$4.99/mo', style: const TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildSpecialOfferCard(String title, String desc, int cost, int originalCost, int minutes) {
    bool canAfford = credits >= cost;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BoltColors.electricOrange.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: BoltColors.electricOrange, fontWeight: FontWeight.bold, fontSize: 15)),
              Text(desc, style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('$cost Credits ', style: const TextStyle(color: BoltColors.warning, fontWeight: FontWeight.bold)),
                  Text('$originalCost', style: const TextStyle(color: BoltColors.textSecondary, decoration: TextDecoration.lineThrough, fontSize: 11)),
                ],
              ),
            ],
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: canAfford ? BoltColors.electricOrange : BoltColors.surfaceLight,
              foregroundColor: canAfford ? Colors.black : BoltColors.textSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: canAfford ? () => _redeemCreditsForTime(cost, minutes) : null,
            child: const Text('Redeem'),
          ),
        ],
      ),
    );
  }

  Widget _buildStandardRedeemTile(int cost, int minutes) {
    bool canAfford = credits >= cost;
    return Card(
      color: BoltColors.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: canAfford ? BoltColors.neonCyan.withOpacity(0.3) : BoltColors.surfaceBorder),
      ),
      child: ListTile(
        title: Text('$minutes Minute${minutes > 1 ? 's' : ''} Scroll Time', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text('Cost: $cost Credits', style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
        trailing: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: canAfford ? BoltColors.neonCyan : BoltColors.surfaceLight,
            foregroundColor: canAfford ? Colors.black : BoltColors.textSecondary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: canAfford ? () => _redeemCreditsForTime(cost, minutes) : null,
          child: const Text('Redeem'),
        ),
      ),
    );
  }

  void _redeemCreditsForTime(int cost, int minutes) {
    if (credits >= cost) {
      setState(() {
        credits -= cost;
        _allowedScrollTimeSeconds += (minutes * 60);
        _isAppBlocked = false;
      });
      _saveData();
      _showSnackBar('Unlocked $minutes minutes of scroll allowance!');
    }
  }

  // ------------------------------------------
  // TAB 4: ANALYTICS & APP ICON GRAPHIC
  // ------------------------------------------
  Widget _buildAnalyticsTab() {
    // CORRECTED 10-YEAR LIFE WASTE MATH:
    // (dailyScreenHours * 365 days * 10 years) / (24 hours * 365 days) = (dailyScreenHours * 10) / 24 YEARS
    final double wastedYearsIn10Years = (_dailyScreenHours * 10.0) / 24.0;

    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Analytics & Reality Check', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 16),

              // CORRECTED REALITY CHECK CARD
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: BoltColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BoltColors.danger.withOpacity(0.6)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: BoltColors.danger, size: 36),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('10-Year Life Waste Calculation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 4),
                          Text(
                            'At your average of ${_dailyScreenHours.toStringAsFixed(1)} hrs/day, you will spend exactly ${wastedYearsIn10Years.toStringAsFixed(1)} YEARS glued to screen over the next decade.',
                            style: const TextStyle(color: BoltColors.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              _analyticsRowCard('Squats Tracked', '$squatsCount reps', Icons.accessibility_new_rounded, BoltColors.neonCyan),
              _analyticsRowCard('Total Steps', '$_stepCount steps', Icons.directions_walk_rounded, BoltColors.neonGreen),
              _analyticsRowCard('Scroll Allowance Unlocked', '${_allowedScrollTimeSeconds ~/ 60} mins', Icons.timer_rounded, BoltColors.warning),

              const SizedBox(height: 24),
              const Text('Custom Geometric App Icon Graphic', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: BoltColors.surfaceBorder),
                      ),
                      child: const FitPayAppIconGraphic(),
                    ),
                    const SizedBox(height: 6),
                    const Text('Geometric Push-Up Character Concept', style: TextStyle(color: BoltColors.textSecondary, fontSize: 11)),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              GestureDetector(
                onTap: () {
                  _adminTapCount++;
                  if (_adminTapCount >= 5) {
                    setState(() => _isAdminVisible = !_isAdminVisible);
                    _showSnackBar('Admin Panel Toggled');
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: BoltColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: BoltColors.surfaceBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('FitPay App Version 2.0.0', style: TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
                      if (_isAdminVisible) const Icon(Icons.admin_panel_settings_rounded, color: BoltColors.neonCyan),
                    ],
                  ),
                ),
              ),
              if (_isAdminVisible) _buildAdminPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analyticsRowCard(String label, String value, IconData icon, Color color) {
    return Card(
      color: BoltColors.surface,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
        trailing: Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    );
  }

  Widget _buildAdminPanel() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BoltColors.neonCyan),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('👑 Developer Controls', style: TextStyle(color: BoltColors.neonCyan, fontWeight: FontWeight.bold)),
          ElevatedButton(
            onPressed: () {
              setState(() => credits += 1000);
              _saveData();
            },
            child: const Text('Add 1000 Credits'),
          ),
        ],
      ),
    );
  }

  // ---------- CAMERA IMAGE ROTATION WRAPPER ----------
  _InputImageResult? _inputImageFromCameraImage(CameraImage image) {
    final cam = controller;
    if (cam == null) return null;
    final camera = cam.description;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[cam.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (camera.sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (camera.sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
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
    final isRotated90or270 = rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg;
    final adjustedSize = isRotated90or270 ? Size(rawSize.height, rawSize.width) : rawSize;
    return _InputImageResult(inputImage: inputImage, adjustedSize: adjustedSize);
  }

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
}

// ==========================================
// HIGH-END MODERN ONBOARDING FLOW
// ==========================================
class OnboardingFlow extends StatefulWidget {
  final Function(int targetMinutes, double screenHours, String motivation, WorkoutMode mode, UserLevel level) onComplete;
  const OnboardingFlow({super.key, required this.onComplete});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  double _screenHours = 6.0;
  int _targetMinutes = 30;
  String _motivation = 'Reduce screen time';
  WorkoutMode _mode = WorkoutMode.both;
  UserLevel _level = UserLevel.beginner;

  void _next() {
    if (_currentStep < 5) {
      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (index) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentStep == index ? 28 : 8,
                    height: 6,
                    decoration: BoxDecoration(
                      color: _currentStep == index ? BoltColors.neonCyan : BoltColors.surfaceBorder,
                      borderRadius: BorderRadius.circular(3),
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
                  _stepDailyScreenTime(),
                  _stepTargetScrollAllowance(),
                  _stepMotivation(),
                  _stepWorkoutModeSelection(),
                  _stepDifficultyLevel(),
                  _stepFinalReady(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BoltColors.neonCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _next,
                  child: Text(_currentStep == 5 ? 'Launch FitPay' : 'Continue', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepDailyScreenTime() {
    // Corrected 10-Year Waste Calculation Formula:
    final double yearsWasted = (_screenHours * 10.0) / 24.0;

    return _onboardingCard(
      title: 'Daily Screen Time',
      child: Column(
        children: [
          const Text('How many hours do you spend on your phone daily?', style: TextStyle(color: BoltColors.textSecondary, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Slider(
            value: _screenHours,
            min: 1,
            max: 16,
            divisions: 15,
            activeColor: BoltColors.neonCyan,
            onChanged: (v) => setState(() => _screenHours = v),
          ),
          Text('${_screenHours.toStringAsFixed(1)} hours/day', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: BoltColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: BoltColors.danger),
            ),
            child: Text(
              ' Reality Check: At this rate, you will waste ${yearsWasted.toStringAsFixed(1)} YEARS of your life on your phone in the next 10 years!',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BoltColors.danger, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepTargetScrollAllowance() {
    return _onboardingCard(
      title: 'Target Daily Allowance',
      child: Column(
        children: [
          const Text('How many minutes of unlocked phone time do you want daily?', style: TextStyle(color: BoltColors.textSecondary, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Slider(
            value: _targetMinutes.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            activeColor: BoltColors.neonCyan,
            onChanged: (v) => setState(() => _targetMinutes = v.round()),
          ),
          Text('$_targetMinutes Minutes', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _stepMotivation() {
    return _onboardingCard(
      title: 'Primary Goal',
      child: Column(
        children: ['Reduce screen time', 'Lose weight & stay fit', 'Build daily discipline', 'Boost overall activity']
            .map((m) => Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ChoiceChip(
                    label: Text(m, style: const TextStyle(fontSize: 14)),
                    selected: _motivation == m,
                    onSelected: (_) => setState(() => _motivation = m),
                    selectedColor: BoltColors.neonCyan.withOpacity(0.2),
                    backgroundColor: BoltColors.surface,
                    labelStyle: TextStyle(color: _motivation == m ? BoltColors.neonCyan : Colors.white),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _stepWorkoutModeSelection() {
    return _onboardingCard(
      title: 'Exercise Mode',
      child: Column(
        children: [
          _modeOption('Squats Only (Pose AI)', WorkoutMode.squatsOnly),
          _modeOption('Walking Only (Pedometer & GPS)', WorkoutMode.walkingOnly),
          _modeOption('Both (Squats + Walking)', WorkoutMode.both),
        ],
      ),
    );
  }

  Widget _modeOption(String label, WorkoutMode mode) {
    bool isSelected = _mode == mode;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => setState(() => _mode = mode),
        selectedColor: BoltColors.neonCyan.withOpacity(0.2),
        backgroundColor: BoltColors.surface,
        labelStyle: TextStyle(color: isSelected ? BoltColors.neonCyan : Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _stepDifficultyLevel() {
    return _onboardingCard(
      title: 'Fitness Level',
      child: Column(
        children: [
          _levelCard('Beginner', '1 Squat = 200 Credits (2 mins)\n100m Walk = 100 Credits', UserLevel.beginner),
          _levelCard('Intermediate', '1 Squat = 100 Credits (1 min)\n100m Walk = 50 Credits', UserLevel.intermediate),
          _levelCard('Beast Mode', '2 Squats = 100 Credits\n100m Walk = 25 Credits', UserLevel.beast),
        ],
      ),
    );
  }

  Widget _levelCard(String name, String rate, UserLevel lvl) {
    bool isSelected = _level == lvl;
    return GestureDetector(
      onTap: () => setState(() => _level = lvl),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BoltColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isSelected ? BoltColors.neonCyan : BoltColors.surfaceBorder, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: TextStyle(color: isSelected ? BoltColors.neonCyan : Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 2),
            Text(rate, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _stepFinalReady() {
    return _onboardingCard(
      title: 'Ready to Transform?',
      child: const Column(
        children: [
          SizedBox(
            width: 100,
            height: 100,
            child: FitPayAppIconGraphic(),
          ),
          SizedBox(height: 16),
          Text(
            'Exercises earn Credits.\nCredits buy Scroll Time.\nNo shortcuts!',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _onboardingCard({required String title, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 24),
          child,
        ],
      ),
    );
  }
}

// ==========================================
// CUSTOM GEOMETRIC APP ICON GRAPHIC WIDGET
// ==========================================
class FitPayAppIconGraphic extends StatelessWidget {
  const FitPayAppIconGraphic({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: AppIconPainter(),
    );
  }
}

class AppIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // Outer Background Container
    final bgPaint = Paint()..color = Colors.black;
    canvas.drawRRect(RRect.fromLTRBR(0, 0, w, h, const Radius.circular(18)), bgPaint);

    final whitePaint = Paint()..color = Colors.white;
    final orangePaint = Paint()..color = BoltColors.electricOrange;

    // 1. Center Circle Head (Push-up athlete head)
    canvas.drawCircle(Offset(w * 0.5, h * 0.32), w * 0.09, orangePaint);

    // 2. Central Rectangle (Torso Plank)
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.30, h * 0.46, w * 0.70, h * 0.56, const Radius.circular(5)),
      whitePaint,
    );

    // 3. Left Rectangle (Arm Support Left)
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.16, h * 0.50, w * 0.26, h * 0.60, const Radius.circular(5)),
      orangePaint,
    );

    // 4. Right Rectangle (Arm Support Right)
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.74, h * 0.50, w * 0.84, h * 0.60, const Radius.circular(5)),
      orangePaint,
    );

    // 5. Four Outer Edge Rectangles (Soft Edge Boundary Pillars)
    // Top-Left Edge
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.12, h * 0.16, w * 0.24, h * 0.24, const Radius.circular(4)),
      whitePaint,
    );
    // Top-Right Edge
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.76, h * 0.16, w * 0.88, h * 0.24, const Radius.circular(4)),
      whitePaint,
    );
    // Bottom-Left Edge
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.12, h * 0.76, w * 0.24, h * 0.84, const Radius.circular(4)),
      orangePaint,
    );
    // Bottom-Right Edge
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.76, h * 0.76, w * 0.88, h * 0.84, const Radius.circular(4)),
      orangePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ==========================================
// ML KIT NEON SKELETON PAINTER
// ==========================================
class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  static const double _minLikelihood = 0.5;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width == 0 || imageSize.height == 0) return;

    final linePaint = Paint()
      ..color = BoltColors.neonCyan
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final glowPaint = Paint()
      ..color = BoltColors.neonCyan.withOpacity(0.35)
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset? getPoint(PoseLandmarkType type) {
      final landmark = pose.landmarks[type];
      if (landmark == null || landmark.likelihood < _minLikelihood) return null;
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
      if (landmark.likelihood >= _minLikelihood) {
        final point = Offset(landmark.x * scaleX, landmark.y * scaleY);
        canvas.drawCircle(point, 3.0, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) {
    return oldDelegate.pose != pose || oldDelegate.imageSize != imageSize;
  }
}

class _InputImageResult {
  final InputImage inputImage;
  final Size adjustedSize;
  const _InputImageResult({required this.inputImage, required this.adjustedSize});
}
