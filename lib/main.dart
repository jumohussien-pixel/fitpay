import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/fitpay_session_bridge.dart';
import 'services/fitpay_sdk_setup.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FitPaySdkSetup.initialize();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Camera initialization error: $e");
  }
  runApp(const FitPayApp());
}

// ==========================================
// COLOR PALETTE
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
// MODELS & ENUMS
// ==========================================
enum UserLevel { beginner, intermediate, advanced }
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

class PermissionState {
  final bool usageStats;
  final bool overlay;
  final bool activityRecognition;

  const PermissionState({
    required this.usageStats,
    required this.overlay,
    required this.activityRecognition,
  });

  bool get canStartBlocking => usageStats && overlay;
}

// ==========================================
// APP ROOT
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
      ),
      home: const MainScreen(),
    );
  }
}

class FitPayAppIconGraphic extends StatelessWidget {
  const FitPayAppIconGraphic({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BoltColors.surfaceLight,
        shape: BoxShape.circle,
        border: Border.all(color: BoltColors.neonCyan, width: 1.5),
      ),
      child: const Center(
        child: Icon(Icons.bolt_rounded, color: BoltColors.neonCyan, size: 22),
      ),
    );
  }
}

// ==========================================
// MAIN SCREEN
// ==========================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? controller;
  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String? _cameraError;
  bool _isFrontCamera = true;

  double credits = 0.0;
  int squatsCount = 0;
  int stepCount = 0;
  int _lastProcessedRelativeSteps = 0;

  UserLevel level = UserLevel.beginner;
  WorkoutMode workoutMode = WorkoutMode.both;

  String _sessionMode = 'squats';
  int _squatGoal = 10;
  int _stepGoal = 100;
  int _sessionCount = 0;
  bool _sessionActive = false;
  DateTime? _lastPoseFrameAt;
  StreamSubscription<Map<dynamic, dynamic>>? _sessionEventSub;

  int _allowedScrollTimeSeconds = 0;
  bool _showSuccessFlash = false;
  bool isProUser = false;

  PermissionState _permissions = const PermissionState(
    usageStats: false,
    overlay: false,
    activityRecognition: false,
  );
  List<AppInfo> _installedApps = [];

  int _streak = 0;
  String _lastWorkoutDate = '';
  String _selectedMotivation = 'Reduce screen time';
  int _dailyTargetScrollMinutes = 30;
  double _dailyScreenHours = 6.0;

  bool _onboardingComplete = false;
  bool _isAdminVisible = false;
  int _adminTapCount = 0;
  int _selectedTab = 0;

  late final AnimationController _pulseController;
  late final AnimationController _repController;
  Timer? _uiRefreshTimer;

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

    _loadDefaultAppsList();
    _loadData();
    _sessionEventSub = FitPaySessionBridge.events.listen(_handleSessionEvent);
    _checkAllPermissions();
    _refreshSessionState();

    // Periodic UI sync with native SharedPreferences (read-only)
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _syncActiveSecondsFromNative();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiRefreshTimer?.cancel();
    _pulseController.dispose();
    _repController.dispose();
    _stopStreamSafely();
    controller?.dispose();
    _sessionEventSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _stopStreamSafely();
      _saveData();
    } else if (state == AppLifecycleState.resumed) {
      _checkAllPermissions();
      _refreshSessionState();
      _syncActiveSecondsFromNative();

      if (_selectedTab == 0 && _sessionActive && _sessionMode == 'squats') {
        if (_isCameraInitialized && !_isStreaming) {
          _startStreamSafely();
        } else {
          _initializeCamera();
        }
      }
    }
  }

  Future<void> _syncActiveSecondsFromNative() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final currentSecs = prefs.getInt('scroll_time_seconds') ?? 0;
    final currentCreds = prefs.getDouble('credits') ?? (prefs.getInt('credits')?.toDouble() ?? 0.0);
    setState(() {
      _allowedScrollTimeSeconds = currentSecs;
      credits = currentCreds;
    });
  }

  int get _sessionGoal => _sessionMode == 'squats' ? _squatGoal : _stepGoal;

  void _handleSessionEvent(Map<dynamic, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String?;
    if (type == 'openWorkout') {
      _selectTab(0);
      _refreshSessionState();
      return;
    }
    if (type == 'sensorUnavailable') {
      _showSnackBar('No step sensor detected on this device.', isError: true);
      FitPaySessionBridge.stopSession();
      return;
    }
    if (type == 'overlayPermissionMissing') {
      _showSnackBar('Enable overlay permission to block apps.', isError: true);
      FitPaySessionBridge.stopSession();
      return;
    }
    if (type == 'sessionState' || type == 'goalCompleted' || type == 'sessionStopped' || type == 'stepUpdate') {
      final count = (event['count'] as num?)?.toInt() ?? _sessionCount;
      setState(() {
        _sessionCount = count;
        _sessionActive = event['active'] == true;
        if (_sessionMode == 'steps') {
          final newStepsDelta = count - _lastProcessedRelativeSteps;
          if (newStepsDelta > 0) {
            _onStepsRecorded(newStepsDelta);
            _lastProcessedRelativeSteps = count;
          }
          stepCount = count;
        }
      });
      if (type == 'goalCompleted') {
        _showSnackBar('Goal achieved! 10 Minutes unlocked!');
      } else if (type == 'sessionStopped') {
        _showSnackBar('Session stopped.');
      }
    }
  }

  Future<void> _checkAllPermissions() async {
    try {
      final result = await FitPaySessionBridge.checkPermissions();
      if (mounted) {
        setState(() {
          _permissions = PermissionState(
            usageStats: result.usageStats,
            overlay: result.overlay,
            activityRecognition: result.activityRecognition,
          );
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshSessionState() async {
    try {
      final snapshot = await FitPaySessionBridge.getSessionState();
      if (!mounted) return;
      setState(() {
        _sessionActive = snapshot.active;
        _sessionMode = snapshot.mode;
        _sessionCount = snapshot.count;
        if (snapshot.mode == 'steps') stepCount = snapshot.count;
      });
      if (snapshot.active && snapshot.mode == 'squats' && _selectedTab == 0 && !_isCameraInitialized) {
        _initializeCamera();
      }
    } catch (_) {}
  }

  Future<void> _requestOverlayPermission() async {
    await FitPaySessionBridge.requestOverlayPermission();
  }

  Future<void> _requestUsagePermission() async {
    await FitPaySessionBridge.requestUsageStatsPermission();
  }

  Future<void> _startBlockingSession() async {
    await _checkAllPermissions();
    if (!_permissions.canStartBlocking) {
      _showSnackBar('Enable Overlay and Usage Access first.', isError: true);
      return;
    }
    if (!_permissions.activityRecognition) {
      await FitPaySessionBridge.requestActivityRecognitionPermission();
      _showSnackBar('Allow physical activity recognition, then tap Start.');
      return;
    }
    final selectedPackages = _installedApps
        .where((app) => app.isBlocked)
        .map((app) => app.packageName)
        .toList();
    if (selectedPackages.isEmpty) {
      _showSnackBar('Select at least one app to block.', isError: true);
      return;
    }
    try {
      await FitPaySdkSetup.requestNotificationPermission();
      _lastProcessedRelativeSteps = 0;
      await FitPaySessionBridge.startSession(
        mode: _sessionMode,
        goal: _sessionGoal,
        packages: selectedPackages,
      );
      setState(() {
        _sessionActive = true;
        _sessionCount = 0;
        if (_sessionMode == 'steps') stepCount = 0;
        if (_sessionMode == 'squats') squatsCount = 0;
      });
      if (_sessionMode == 'squats') {
        _selectTab(0);
        _initializeCamera();
      }
    } on PlatformException catch (error) {
      _showSnackBar(error.message ?? 'Could not start session.', isError: true);
      _checkAllPermissions();
    }
  }

  Future<void> _stopBlockingSession() async {
    await FitPaySessionBridge.stopSession();
    _stopStreamSafely();
    if (mounted) setState(() => _sessionActive = false);
  }

  void _selectTab(int index) {
    if (_selectedTab == index) return;
    setState(() => _selectedTab = index);
    if (index == 0) {
      if (_sessionActive && _sessionMode == 'squats') {
        _initializeCamera();
      }
    } else {
      _stopStreamSafely();
      controller?.dispose();
      controller = null;
      _isCameraInitialized = false;
      _isStreaming = false;
    }
  }

  void _loadDefaultAppsList() {
    _installedApps = [
      AppInfo(packageName: 'com.facebook.katana', appName: 'Facebook', isBlocked: true, icon: Icons.facebook_rounded),
      AppInfo(packageName: 'com.instagram.android', appName: 'Instagram', isBlocked: true, icon: Icons.camera_alt_rounded),
      AppInfo(packageName: 'com.zhiliaoapp.musically', appName: 'TikTok', isBlocked: true, icon: Icons.video_library_rounded),
      AppInfo(packageName: 'com.google.android.youtube', appName: 'YouTube', isBlocked: false, icon: Icons.play_circle_fill_rounded),
      AppInfo(packageName: 'com.twitter.android', appName: 'X / Twitter', isBlocked: false, icon: Icons.alternate_email_rounded),
      AppInfo(packageName: 'com.snapchat.android', appName: 'Snapchat', isBlocked: false, icon: Icons.snapchat_rounded),
      AppInfo(packageName: 'com.reddit.frontpage', appName: 'Reddit', isBlocked: false, icon: Icons.forum_rounded),
    ];
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      credits = prefs.getDouble('credits') ?? (prefs.getInt('credits')?.toDouble() ?? 0.0);
      squatsCount = prefs.getInt('squatsCount') ?? 0;
      stepCount = prefs.getInt('stepCount') ?? 0;

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
    await prefs.setDouble('credits', credits);
    await prefs.setInt('squatsCount', squatsCount);
    await prefs.setInt('stepCount', stepCount);
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

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      if (mounted) setState(() => _cameraError = "No camera available.");
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
      if (mounted) {
        setState(() => _cameraError = 'Camera permission required for squat detection.');
      }
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
    if (!_sessionActive || _sessionMode != 'squats' || _selectedTab != 0 || image.planes.isEmpty) {
      _isDetecting = false;
      return;
    }
    final now = DateTime.now();
    if (_lastPoseFrameAt != null && now.difference(_lastPoseFrameAt!).inMilliseconds < 250) {
      _isDetecting = false;
      return;
    }
    _lastPoseFrameAt = now;
    try {
      final repCompleted = await FitPaySessionBridge.processSquatFrame(
        bytes: image.planes.first.bytes,
        width: image.width,
        height: image.height,
        rotationDegrees: controller?.description.sensorOrientation ?? 0,
      );
      if (repCompleted && mounted) _onSquatCompleted();
    } catch (_) {} finally {
      _isDetecting = false;
    }
  }

  // ==========================================
  // CREDITS ENGINE & AUTO-UNLOCK
  // ==========================================
  void _onSquatCompleted() {
    if (!mounted) return;

    double awardedCredits = switch (level) {
      UserLevel.beginner => 10.0,
      UserLevel.intermediate => 5.0,
      UserLevel.advanced => 2.5,
    };

    setState(() {
      squatsCount++;
      credits += awardedCredits;
      _sessionCount++;
      _showSuccessFlash = true;

      // AUTOMATIC: When 10 squats completed -> Unlock 10 minutes (600 seconds)
      if (_sessionCount >= _sessionGoal) {
        _allowedScrollTimeSeconds += 600;
        _sessionCount = 0;
        _showSnackBar('🎉 10 Reps Complete! 10 Minutes unlocked for target apps!');
      }
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

  void _onStepsRecorded(int relativeSteps) {
    if (relativeSteps <= 0) return;

    double creditsPerStep = switch (level) {
      UserLevel.beginner => 5.0 / 10.0,
      UserLevel.intermediate => 2.5 / 10.0,
      UserLevel.advanced => 1.0 / 10.0,
    };

    setState(() {
      credits += (relativeSteps * creditsPerStep);
    });
    _updateStreak();
    _saveData();
  }

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

  String _formatCredits(double c) {
    return c % 1 == 0 ? c.toInt().toString() : c.toStringAsFixed(1);
  }

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
          onTap: _selectTab,
          type: BottomNavigationBarType.fixed,
          backgroundColor: BoltColors.surface,
          selectedItemColor: BoltColors.neonCyan,
          unselectedItemColor: BoltColors.textSecondary,
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                    Text('${_formatCredits(credits)} C', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)),
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
        padding: const EdgeInsets.all(12),
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
                    const Text('Active Screen Time Allowance', style: TextStyle(color: BoltColors.textSecondary, fontSize: 11)),
                    Text(
                      hasTime ? '$mins mins $secs secs remaining' : 'Apps Locked - Complete 10 squats',
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
              onPressed: () => setState(() => _selectedTab = 2),
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
    if (!_sessionActive || _sessionMode != 'squats') {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.fitness_center_rounded, color: BoltColors.textSecondary, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Camera Dormant',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Start session to activate MediaPipe detector',
              style: TextStyle(color: BoltColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: BoltColors.neonCyan,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                setState(() => _sessionMode = 'squats');
                _startBlockingSession();
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Start Squats Session', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
    if (_cameraError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded, color: BoltColors.textSecondary, size: 48),
            const SizedBox(height: 8),
            Text(_cameraError!, style: const TextStyle(color: BoltColors.textSecondary), textAlign: TextAlign.center),
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
      child: CameraPreview(controller!),
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
              _statCard('Steps', '$stepCount', BoltColors.neonGreen, Icons.directions_walk_rounded),
              _statCard('Credits', '${_formatCredits(credits)} C', BoltColors.warning, Icons.monetization_on_rounded),
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
                    _levelChoiceChip('Intermediate', UserLevel.intermediate),
                    _levelChoiceChip('Advanced', UserLevel.advanced),
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
      width: 105,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: BoltColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 2),
          Text(title, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 10)),
          Text(value, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w900)),
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

  Widget _buildAppLockTab() {
    int currentlyBlockedCount = _installedApps.where((a) => a.isBlocked).length;

    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
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
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Apps intercepted by the system lock screen.', style: TextStyle(color: BoltColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 14),
            _buildPermissionsDashboard(),
            const SizedBox(height: 14),
            _buildSessionControls(),
            const SizedBox(height: 14),
            for (final app in _installedApps)
              Card(
                color: BoltColors.surface,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: app.isBlocked ? BoltColors.neonCyan.withOpacity(0.5) : BoltColors.surfaceBorder),
                ),
                child: SwitchListTile(
                  activeColor: BoltColors.neonCyan,
                  secondary: Icon(app.icon, color: app.isBlocked ? BoltColors.neonCyan : BoltColors.textSecondary),
                  title: Text(app.appName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(app.packageName, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 10)),
                  value: app.isBlocked,
                  onChanged: _sessionActive
                      ? null
                      : (value) {
                          if (value && !isProUser && currentlyBlockedCount >= 3) {
                            _showProUpgradeModal();
                          } else {
                            setState(() => app.isBlocked = value);
                            _saveData();
                          }
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionsDashboard() {
    final ready = _permissions.canStartBlocking;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BoltColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ready ? BoltColors.neonGreen.withOpacity(0.4) : BoltColors.warning.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Required permissions', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              Icon(ready ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                  color: ready ? BoltColors.neonGreen : BoltColors.warning),
            ],
          ),
          const SizedBox(height: 10),
          _permissionRow('Usage Stats (Detect foreground apps)', _permissions.usageStats, _requestUsagePermission),
          _permissionRow('System Overlay (Display blocking window)', _permissions.overlay, _requestOverlayPermission),
        ],
      ),
    );
  }

  Widget _buildSessionControls() {
    final isSquats = _sessionMode == 'squats';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: BoltColors.surface, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Active Session Controls', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'squats', label: Text('Squats'), icon: Icon(Icons.fitness_center_rounded)),
              ButtonSegment(value: 'steps', label: Text('Steps'), icon: Icon(Icons.directions_walk_rounded)),
            ],
            selected: {_sessionMode},
            onSelectionChanged: _sessionActive
                ? null
                : (selection) {
                    setState(() {
                      _sessionMode = selection.first;
                      _sessionCount = 0;
                    });
                  },
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(isSquats ? 'Squat goal' : 'Step goal', style: const TextStyle(color: BoltColors.textSecondary)),
              Text('$_sessionGoal', style: const TextStyle(color: BoltColors.neonCyan, fontWeight: FontWeight.w900, fontSize: 18)),
            ],
          ),
          Slider(
            value: _sessionGoal.toDouble(),
            min: isSquats ? 1 : 10,
            max: isSquats ? 50 : 1000,
            divisions: 99,
            label: '$_sessionGoal',
            onChanged: _sessionActive
                ? null
                : (value) => setState(() {
                      if (isSquats) {
                        _squatGoal = value.round();
                      } else {
                        _stepGoal = (value / 10).round() * 10;
                      }
                    }),
          ),
          Text(
            _sessionActive ? 'Progress: $_sessionCount / $_sessionGoal' : 'Sensors fire only when session is active.',
            style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sessionActive ? _stopBlockingSession : _startBlockingSession,
              icon: Icon(_sessionActive ? Icons.stop_rounded : Icons.play_arrow_rounded),
              label: Text(_sessionActive ? 'Stop session' : 'Start blocking session'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionRow(String label, bool isGranted, VoidCallback onRequest) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                  isGranted ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  color: isGranted ? BoltColors.neonGreen : BoltColors.danger,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(color: BoltColors.textSecondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (!isGranted)
            InkWell(
              onTap: onRequest,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text('Enable', style: TextStyle(color: BoltColors.neonCyan, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ),
        ],
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
          'Free Tier allows locking up to 3 apps. Upgrade to FitPay Pro to lock unlimited apps and unlock exclusive perks!',
          style: TextStyle(color: BoltColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: BoltColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: BoltColors.electricOrange, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              setState(() => _selectedTab = 2);
            },
            child: const Text('Upgrade to Pro', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // CREDITS STORE (100 Credits = 10 Minutes)
  // ==========================================
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
              Text('Available Balance: ${_formatCredits(credits)} Credits', style: const TextStyle(color: BoltColors.warning, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),

              const Text('Standard Rate: 100 Credits = 10 Minutes Active Screen Time', style: TextStyle(color: BoltColors.neonCyan, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),

              _buildStandardRedeemTile(100, 10),
              _buildStandardRedeemTile(200, 20),
              _buildStandardRedeemTile(300, 30),
              _buildStandardRedeemTile(600, 60),

              const SizedBox(height: 28),
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
                    const Text('Unlimited app blocking, zero ads, priority lightweight sensors', textAlign: TextAlign.center, style: TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
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

  Widget _buildStandardRedeemTile(int costCredits, int minutes) {
    bool canAfford = credits >= costCredits;
    return Card(
      color: BoltColors.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: canAfford ? BoltColors.neonCyan.withOpacity(0.3) : BoltColors.surfaceBorder),
      ),
      child: ListTile(
        leading: const Icon(Icons.hourglass_bottom_rounded, color: BoltColors.neonCyan),
        title: Text('$minutes Minutes Screen Time', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text('Cost: $costCredits Credits', style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
        trailing: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: canAfford ? BoltColors.neonCyan : BoltColors.surfaceLight,
            foregroundColor: canAfford ? Colors.black : BoltColors.textSecondary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: canAfford ? () => _redeemCreditsForTime(costCredits, minutes) : null,
          child: const Text('Spend'),
        ),
      ),
    );
  }

  void _redeemCreditsForTime(int cost, int minutes) {
    if (credits >= cost) {
      setState(() {
        credits -= cost;
        _allowedScrollTimeSeconds += (minutes * 60);
      });
      _saveData();
      _showSnackBar('Unlocked $minutes minutes of active screen time!');
    }
  }

  Widget _buildAnalyticsTab() {
    final double wastedYearsIn10Years = (_dailyScreenHours * 10.0) / 24.0;

    return Container(
      color: BoltColors.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Activity & Analytics', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 16),

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
                          const Text('10-Year Screen Time Projection', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 4),
                          Text(
                            'At ${_dailyScreenHours.toStringAsFixed(1)} hrs/day, you will spend ${wastedYearsIn10Years.toStringAsFixed(1)} YEARS glued to apps over the next decade.',
                            style: const TextStyle(color: BoltColors.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              _analyticsRowCard('Total Squats Tracked', '$squatsCount reps', Icons.accessibility_new_rounded, BoltColors.neonCyan),
              _analyticsRowCard('Active Steps Counted', '$stepCount steps', Icons.directions_walk_rounded, BoltColors.neonGreen),
              _analyticsRowCard('Credits Balance', '${_formatCredits(credits)} C', Icons.monetization_on_rounded, BoltColors.warning),
              _analyticsRowCard('Active Screen Time Left', '${_allowedScrollTimeSeconds ~/ 60} mins ${_allowedScrollTimeSeconds % 60}s', Icons.timer_rounded, BoltColors.electricOrange),

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
                      const Text('FitPay Version 3.0.0 (Hackathon Release)', style: TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
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
          const Text('Developer Controls', style: TextStyle(color: BoltColors.neonCyan, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                onPressed: () {
                  setState(() => credits += 100);
                  _saveData();
                },
                child: const Text('+100 Credits'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() => _allowedScrollTimeSeconds += 600);
                  _saveData();
                },
                child: const Text('+10 Mins Time'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() => _allowedScrollTimeSeconds = 0);
                  _saveData();
                },
                child: const Text('Expire Time'),
              ),
            ],
          )
        ],
      ),
    );
  }
}

// ==========================================
// ONBOARDING FLOW
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
  WorkoutMode _mode = WorkoutMode.squatsOnly;
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.phonelink_setup_rounded, color: BoltColors.neonCyan, size: 64),
          const SizedBox(height: 20),
          const Text('Estimated Daily Screen Time', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('How many hours do you spend on target apps daily?', style: TextStyle(color: BoltColors.textSecondary, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Text('${_screenHours.toStringAsFixed(1)} Hours / day', style: const TextStyle(color: BoltColors.neonCyan, fontSize: 32, fontWeight: FontWeight.w900)),
          Slider(
            value: _screenHours,
            min: 1.0,
            max: 14.0,
            divisions: 26,
            activeColor: BoltColors.neonCyan,
            inactiveColor: BoltColors.surfaceBorder,
            onChanged: (val) => setState(() => _screenHours = val),
          ),
        ],
      ),
    );
  }

  Widget _stepTargetScrollAllowance() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_rounded, color: BoltColors.neonGreen, size: 64),
          const SizedBox(height: 20),
          const Text('Target Scroll Allowance Goal', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('How many minutes of screen time do you aim to allow per unlock?', style: TextStyle(color: BoltColors.textSecondary, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Text('$_targetMinutes Minutes', style: const TextStyle(color: BoltColors.neonGreen, fontSize: 32, fontWeight: FontWeight.w900)),
          Slider(
            value: _targetMinutes.toDouble(),
            min: 5.0,
            max: 120.0,
            divisions: 23,
            activeColor: BoltColors.neonGreen,
            inactiveColor: BoltColors.surfaceBorder,
            onChanged: (val) => setState(() => _targetMinutes = val.toInt()),
          ),
        ],
      ),
    );
  }

  Widget _stepMotivation() {
    final options = ['Reduce screen time', 'Build workout habits', 'Boost daily productivity', 'Improve sleep quality'];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.psychology_rounded, color: BoltColors.electricOrange, size: 64),
          const SizedBox(height: 20),
          const Text('Primary Motivation', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ...options.map((opt) {
            final selected = _motivation == opt;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: BorderSide(color: selected ? BoltColors.electricOrange : BoltColors.surfaceBorder, width: selected ? 2 : 1),
                  backgroundColor: selected ? BoltColors.electricOrange.withOpacity(0.15) : BoltColors.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => setState(() => _motivation = opt),
                child: Text(opt, style: TextStyle(color: selected ? BoltColors.electricOrange : Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _stepWorkoutModeSelection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.fitness_center_rounded, color: BoltColors.neonCyan, size: 64),
          const SizedBox(height: 20),
          const Text('Preferred Workout Mode', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          _modeCard('Squats AI Detector', WorkoutMode.squatsOnly, Icons.accessibility_new_rounded),
          _modeCard('Step Counter Session', WorkoutMode.walkingOnly, Icons.directions_walk_rounded),
          _modeCard('Hybrid (Steps & Squats)', WorkoutMode.both, Icons.bolt_rounded),
        ],
      ),
    );
  }

  Widget _modeCard(String title, WorkoutMode mode, IconData icon) {
    final selected = _mode == mode;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          side: BorderSide(color: selected ? BoltColors.neonCyan : BoltColors.surfaceBorder, width: selected ? 2 : 1),
          backgroundColor: selected ? BoltColors.neonCyan.withOpacity(0.15) : BoltColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: () => setState(() => _mode = mode),
        icon: Icon(icon, color: selected ? BoltColors.neonCyan : BoltColors.textSecondary),
        label: Text(title, style: TextStyle(color: selected ? BoltColors.neonCyan : Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    );
  }

  Widget _stepDifficultyLevel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.speed_rounded, color: BoltColors.warning, size: 64),
          const SizedBox(height: 20),
          const Text('Select Your Level', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          _levelCard('Beginner', UserLevel.beginner, '1 Squat = 10 Credits | 10 Steps = 5 Credits'),
          _levelCard('Intermediate', UserLevel.intermediate, '1 Squat = 5 Credits | 10 Steps = 2.5 Credits'),
          _levelCard('Advanced', UserLevel.advanced, '1 Squat = 2.5 Credits | 10 Steps = 1 Credit'),
        ],
      ),
    );
  }

  Widget _levelCard(String title, UserLevel lvl, String sub) {
    final selected = _level == lvl;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(16),
          side: BorderSide(color: selected ? BoltColors.warning : BoltColors.surfaceBorder, width: selected ? 2 : 1),
          backgroundColor: selected ? BoltColors.warning.withOpacity(0.15) : BoltColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: () => setState(() => _level = lvl),
        child: Column(
          children: [
            Text(title, style: TextStyle(color: selected ? BoltColors.warning : Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(color: BoltColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _stepFinalReady() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: BoltColors.neonGreen.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(color: BoltColors.neonGreen, width: 2),
            ),
            child: const Icon(Icons.check_circle_outline_rounded, color: BoltColors.neonGreen, size: 72),
          ),
          const SizedBox(height: 24),
          const Text('You are All Set!', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const Text('100 Credits = 10 Minutes active screen time. No GPS, zero battery drain.', style: TextStyle(color: BoltColors.textSecondary, fontSize: 14), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}