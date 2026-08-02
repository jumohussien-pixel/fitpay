import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("خطأ في تحميل الكاميرات: $e");
  }
  runApp(const FitPayApp());
}

enum UserLevel { beginner, intermediate, advanced }

class AppColors {
  static const bg = Color(0xFF0F0F1A);
  static const surface = Color(0xFF1A1A2E);
  static const surfaceLight = Color(0xFF232340);
  static const primary = Color(0xFF6C63FF);
  static const primaryDark = Color(0xFF4B45B3);
  static const neon = Color(0xFF00F0FF);
  static const success = Color(0xFF00E676);
  static const danger = Color(0xFFFF1744);
  static const amber = Color(0xFFFFC107);
}

class FitPayApp extends StatelessWidget {
  const FitPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Fitpay',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Cairo',
        brightness: Brightness.dark,
        primaryColor: AppColors.primary,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.neon,
        ),
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

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const platform = MethodChannel('com.fitpay.app/overlay');

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static const double _minLikelihood = 0.55;
  static const Duration _repCooldown = Duration(milliseconds: 500);
  static const int _smoothingWindow = 4;

  CameraController? controller;
  PoseDetector? _poseDetector;

  int points = 0;
  UserLevel level = UserLevel.beginner;
  int squatsCount = 0;

  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String? _cameraError;

  String _squatState = "up";
  DateTime? _lastSquatTime;
  final List<double> _squatAngleBuffer = [];

  int _allowedScrollTime = 30;
  final int _maxScrollTime = 300;
  Timer? _scrollTimer;
  bool _isAppBlocked = false;
  bool _showSuccessFlash = false;
  bool _isBlockingServiceEnabled = false;

  // القائمة الخاصة بالتطبيقات المحظورة
  final Map<String, Map<String, dynamic>> _appsToBlock = {
    'com.zhiliaoapp.musically': {'name': 'تيك توك', 'blocked': true, 'icon': Icons.video_library_rounded},
    'com.instagram.android': {'name': 'إنستجرام', 'blocked': true, 'icon': Icons.camera_alt_rounded},
    'com.google.android.youtube': {'name': 'يوتيوب Shorts', 'blocked': false, 'icon': Icons.play_circle_fill_rounded},
    'com.facebook.katana': {'name': 'فيسبوك Reels', 'blocked': false, 'icon': Icons.facebook_rounded},
  };

  Pose? _latestPose;
  Size? _imageSize;
  bool _isFrontCamera = true;

  late final AnimationController _pulseController;
  late final AnimationController _repController;

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
    _checkAndRequestPermissions();
    _initializeCamera();
    _startUsageLimitTimer();
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
      if (_isAppBlocked) {
        _forceCloseBackgroundApps();
      }
      if (_isCameraInitialized && !_isStreaming) {
        _startStreamSafely();
      }
    }
  }

  Future<void> _checkAndRequestPermissions() async {
    try {
      final bool hasPermission = await platform.invokeMethod('checkPermissions') ?? false;
      setState(() {
        _isBlockingServiceEnabled = hasPermission;
      });
    } on PlatformException catch (e) {
      debugPrint("مشكلة في التحقق من الصلاحيات: ${e.message}");
    } on MissingPluginException {
      debugPrint("قناة الحظر غير متصلة بالـ Native حالياً.");
    }
  }

  Future<void> _requestBlockingPermission() async {
    try {
      await platform.invokeMethod('requestPermissions');
      _checkAndRequestPermissions();
    } catch (e) {
      _showErrorSnackBar("إفتح إعدادات الجهاز لمنح صلاحية الحجب والظهور فوق التطبيقات.");
    }
  }

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

  Future<void> _forceCloseBackgroundApps() async {
    try {
      final blockedPackages = _appsToBlock.entries
          .where((e) => e.value['blocked'] == true)
          .map((e) => e.key)
          .toList();
      
      await platform.invokeMethod('blockApps', {'packages': blockedPackages});
    } on PlatformException catch (e) {
      debugPrint("فشل حظر التطبيقات: ${e.message}");
    } on MissingPluginException {
      debugPrint("تنبيه: ميزة الحظر تعمل فور ربط كود Android الـ Native.");
    }
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
    } on MissingPluginException {
    } catch (_) {}
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _loadData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        points = prefs.getInt('points') ?? 0;
        squatsCount = prefs.getInt('squatsCount') ?? 0;
        final savedLevel = prefs.getInt('level') ?? 0;
        level = UserLevel.values[savedLevel.clamp(0, UserLevel.values.length - 1)];

        _appsToBlock.forEach((key, value) {
          if (prefs.containsKey('block_$key')) {
            value['blocked'] = prefs.getBool('block_$key') ?? true;
          }
        });
      });
    } catch (e) {
      debugPrint("فشل تحميل البيانات: $e");
    }
  }

  Future<void> _saveData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('points', points);
      await prefs.setInt('squatsCount', squatsCount);
      await prefs.setInt('level', level.index);

      _appsToBlock.forEach((key, value) {
        prefs.setBool('block_$key', value['blocked']);
      });
    } catch (e) {
      debugPrint("فشل حفظ البيانات: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = "لم يتم العثور على كاميرا في الجهاز.");
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
      setState(() => _cameraError = "تعذر تشغيل الكاميرا: ${e.description ?? e.code}");
    } catch (e) {
      setState(() => _cameraError = "خطأ في الكاميرا.");
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
      debugPrint("فشل بث الصور: $e");
    }
  }

  Future<void> _stopStreamSafely() async {
    final cam = controller;
    if (cam == null || !_isStreaming) return;
    try {
      if (cam.value.isStreamingImages) {
        await cam.stopImageStream();
      }
    } catch (e) {
      debugPrint("إيقاف البث: $e");
    } finally {
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
        if (_latestPose != null) {
          setState(() => _latestPose = null);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint("خطأ معالجة الإطار: $e");
    } finally {
      _isDetecting = false;
    }
  }

  double _calculateAngle(PoseLandmark first, PoseLandmark mid, PoseLandmark last) {
    double radians = math.atan2(last.y - mid.y, last.x - mid.x) -
        math.atan2(first.y - mid.y, first.x - mid.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  List<PoseLandmark>? _pickReliableSide(
    Pose pose,
    PoseLandmarkType leftA, PoseLandmarkType leftB, PoseLandmarkType leftC,
    PoseLandmarkType rightA, PoseLandmarkType rightB, PoseLandmarkType rightC,
  ) {
    final left = [pose.landmarks[leftA], pose.landmarks[leftB], pose.landmarks[leftC]];
    final right = [pose.landmarks[rightA], pose.landmarks[rightB], pose.landmarks[rightC]];

    double scoreOf(List<PoseLandmark?> pts) {
      if (pts.any((p) => p == null)) return -1;
      return pts.map((p) => p!.likelihood).reduce(math.min);
    }

    final leftScore = scoreOf(left);
    final rightScore = scoreOf(right);

    if (leftScore < _minLikelihood && rightScore < _minLikelihood) return null;

    final chosen = leftScore >= rightScore ? left : right;
    return [chosen[0]!, chosen[1]!, chosen[2]!];
  }

  double _smooth(List<double> buffer, double newValue) {
    buffer.add(newValue);
    if (buffer.length > _smoothingWindow) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  // خوارزمية السكوات المضبوطة
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

    final angle = _smooth(_squatAngleBuffer, _calculateAngle(side[0], side[1], side[2]));

    if (angle < 100.0) {
      _squatState = "down";
    } else if (angle > 160.0 && _squatState == "down") {
      final now = DateTime.now();
      final canCount = _lastSquatTime == null || now.difference(_lastSquatTime!) > _repCooldown;
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
    _saveData();
  }

  void _openAppSelectionBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'اختيار تطبيقات الحظر',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white54),
                      ),
                    ],
                  ),
                  const Text(
                    'حدد التطبيقات التي سيتم منعك من فتحها عند انتهاء الوقت حتى تمارس السكوات:',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 15),
                  ..._appsToBlock.entries.map((entry) {
                    final pkg = entry.key;
                    final data = entry.value;
                    return SwitchListTile(
                      activeColor: AppColors.neon,
                      secondary: Icon(data['icon'] as IconData, color: AppColors.primary),
                      title: Text(data['name'] as String, style: const TextStyle(color: Colors.white)),
                      value: data['blocked'] as bool,
                      onChanged: (val) {
                        setModalState(() => data['blocked'] = val);
                        setState(() {});
                        _saveData();
                      },
                    );
                  }),
                  const SizedBox(height: 10),
                  if (!_isBlockingServiceEnabled)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.amber,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _requestBlockingPermission();
                      },
                      icon: const Icon(Icons.security, color: Colors.black),
                      label: const Text('تفعيل صلاحيات الحظر الآن', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    double progress = _allowedScrollTime / _maxScrollTime;
    final isLow = _allowedScrollTime <= 10 && !_isAppBlocked;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bg, Color(0xFF15152A)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTimeCard(progress, isLow),
              const SizedBox(height: 10),
              Expanded(flex: 6, child: _buildCameraArea()),
              const SizedBox(height: 10),
              Expanded(flex: 4, child: _buildStatsPanel()),
            ],
          ),
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
              colors: [AppColors.neon, AppColors.primary],
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
              IconButton(
                icon: const Icon(Icons.app_blocking_rounded, color: AppColors.neon, size: 26),
                onPressed: _openAppSelectionBottomSheet,
                tooltip: 'تطبيقات الحظر',
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.amber.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.stars_rounded, color: AppColors.amber, size: 20),
                    const SizedBox(width: 4),
                    Text('$points', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
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
          final glowStrength = (isLow || _isAppBlocked) ? _pulseController.value : 0.0;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: (_isAppBlocked ? AppColors.danger : AppColors.primary)
                    .withOpacity(0.3 + glowStrength * 0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isAppBlocked ? AppColors.danger : AppColors.primary)
                      .withOpacity(0.15 + glowStrength * 0.15),
                  blurRadius: 18,
                  spreadRadius: 1,
                )
              ],
            ),
            child: child,
          );
        },
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isAppBlocked ? Icons.lock_clock_rounded : Icons.timer_outlined,
                      color: _isAppBlocked ? AppColors.danger : AppColors.amber,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isAppBlocked ? 'انتهى الوقت! اعمل سكوات لفك الحظر' : 'الرصيد المتبقي',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
                Text(
                  '$_allowedScrollTime ثانية',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _isAppBlocked ? AppColors.danger : Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 400),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 10,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _isAppBlocked ? AppColors.danger : AppColors.success,
                  ),
                ),
              ),
            ),
          ],
        ),
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
                border: Border.all(color: AppColors.primary, width: 2.5),
                boxShadow: const [
                  BoxShadow(color: Color(0x4D6C63FF), blurRadius: 20, spreadRadius: 2)
                ],
              ),
              child: _buildCameraContent(),
            ),
            if (_showSuccessFlash) ...[
              Container(
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 85),
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
            const Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 48),
            const SizedBox(height: 10),
            Text(_cameraError!, style: const TextStyle(color: Colors.white60)),
            TextButton(
              onPressed: () {
                setState(() => _cameraError = null);
                _initializeCamera();
              },
              child: const Text('إعادة المحاولة', style: TextStyle(color: AppColors.neon)),
            ),
          ],
        ),
      );
    }

    if (!_isCameraInitialized || controller == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
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

  Widget _buildStatsPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
        boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 15, offset: Offset(0, -5))],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatCard('عدد السكوات', squatsCount, AppColors.neon, Icons.accessibility_new_rounded),
              _buildStatCard('مجموع النقاط', points, AppColors.amber, Icons.stars_rounded),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('المستوى: ', style: TextStyle(color: Colors.white54, fontSize: 13)),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: AppColors.surfaceLight, borderRadius: BorderRadius.circular(15)),
                child: Row(
                  children: [
                    _buildLevelChip('مبتدئ', UserLevel.beginner),
                    _buildLevelChip('متوسط', UserLevel.intermediate),
                    _buildLevelChip('وحش', UserLevel.advanced),
                  ],
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, int value, Color color, IconData icon) {
    return Container(
      width: 135,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.4), width: 1.5),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text('$value', style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _buildLevelChip(String label, UserLevel chipLevel) {
    bool isSelected = level == chipLevel;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => level = chipLevel);
          _saveData();
        }
      },
      selectedColor: AppColors.primary,
      backgroundColor: Colors.transparent,
      labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.white60),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

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

    final isRotated90or270 =
        rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final adjustedSize =
        isRotated90or270 ? Size(rawSize.height, rawSize.width) : rawSize;

    return _InputImageResult(inputImage: inputImage, adjustedSize: adjustedSize);
  }
}

class _InputImageResult {
  final InputImage inputImage;
  final Size adjustedSize;
  const _InputImageResult({required this.inputImage, required this.adjustedSize});
}

// رسم خط الهيكل النيون
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
      if (landmark == null || landmark.likelihood < _minLikelihoodToDraw) return null;
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
