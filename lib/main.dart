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
  runApp(const PushBlockApp());
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

class PushBlockApp extends StatelessWidget {
  const PushBlockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat and Scroll',
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
  
  // وقفنا الاتصال بالـ Native مؤقتاً عشان نمنع الـ Crash
  // static const platform = MethodChannel('com.example.sweat_and_scroll_app/overlay');

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static const double _minLikelihood = 0.55; 
  static const Duration _repCooldown = Duration(milliseconds: 600); 
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

  int _allowedScrollTime = 30; // بيبدأ بـ 30 ثانية للتجربة
  final int _maxScrollTime = 300;
  Timer? _scrollTimer;
  bool _isAppBlocked = false;
  bool _showSuccessFlash = false;

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
      if (_isCameraInitialized && !_isStreaming) {
        _startStreamSafely();
      }
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
          // شيلنا دالة الكراش وبقينا بنعتمد على الـ UI المتحدث هنا
        }
      }
    });
  }

  void _addBonusTime(int seconds) {
    if (!mounted) return;
    setState(() {
      _allowedScrollTime =
          (_allowedScrollTime + seconds).clamp(0, _maxScrollTime);
      _isAppBlocked = false; // التطبيق هيفتح تاني بمجرد ما تعمل السكوات
      _showSuccessFlash = true;
    });

    HapticFeedback.mediumImpact();
    _repController.forward().then((_) {
      if (mounted) _repController.reverse();
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });
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
    } catch (e) {
      debugPrint("فشل الحفظ: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = "لم يتم العثور على كاميرا.");
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
      setState(() => _cameraError = "تعذر تشغيل الكاميرا.");
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
      debugPrint("فشل بدء البث");
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
      debugPrint("فشل إيقاف البث");
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
      }
    } catch (e) {
      // تجاهل أخطاء المعالجة
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

  List<PoseLandmark>? _pickReliableSide(Pose pose, PoseLandmarkType leftA, PoseLandmarkType leftB, PoseLandmarkType leftC, PoseLandmarkType rightA, PoseLandmarkType rightB, PoseLandmarkType rightC) {
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

  void _trackSquatImproved(Pose pose) {
    final side = _pickReliableSide(pose, PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle, PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
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
        _addBonusTime(30); // لو عملت عدة واحدة هيفك الحظر ويديك 30 ثانية
      }
    }
  }

  void _onSquatDetected() {
    if (!mounted) return;
    setState(() {
      squatsCount++;
      points += (level == UserLevel.beginner) ? 10 : (level == UserLevel.intermediate) ? 20 : 30;
    });
    _saveData();
  }

  @override
  Widget build(BuildContext context) {
    double progress = _allowedScrollTime / _maxScrollTime;
    final isLow = _allowedScrollTime <= 10 && !_isAppBlocked;

    return Scaffold(
      body: Stack(
        children: [
          Container(
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
                  const SizedBox(height: 16),
                  Expanded(flex: 5, child: _buildCameraArea()),
                  const SizedBox(height: 16),
                  Expanded(flex: 4, child: _buildStatsPanel()),
                ],
              ),
            ),
          ),
          
          // شاشة القفل الداخلية: هتظهر بس لما الوقت يخلص
          if (_isAppBlocked)
            Container(
              color: Colors.black.withOpacity(0.85),
              width: double.infinity,
              height: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_clock_rounded, color: AppColors.danger, size: 100),
                  const SizedBox(height: 20),
                  const Text(
                    'الوقت خلص!',
                    style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'اعمل سكوات دلوقتي عشان تفك القفل وتكمل.',
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                  const SizedBox(height: 30),
                  // الكاميرا مصغرة هنا عشان يشوف نفسه وهو بيعمل السكوات لفك القفل
                  SizedBox(
                    width: 150,
                    height: 200,
                    child: _buildCameraContent(),
                  )
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppColors.neon, AppColors.primary],
            ).createShader(bounds),
            child: const Text(
              'Sweat & Scroll',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24, color: Colors.white),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: AppColors.surfaceLight, borderRadius: BorderRadius.circular(20)),
            child: Row(
              children: [
                const Icon(Icons.stars_rounded, color: AppColors.amber, size: 18),
                const SizedBox(width: 4),
                Text('$points', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeCard(double progress, bool isLow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: (_isAppBlocked ? AppColors.danger : AppColors.primary).withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(_isAppBlocked ? Icons.lock : Icons.timer, color: _isAppBlocked ? AppColors.danger : AppColors.amber),
                    const SizedBox(width: 8),
                    Text(_isAppBlocked ? 'مقفول' : 'الرصيد المتاح', style: const TextStyle(color: Colors.white70)),
                  ],
                ),
                Text('$_allowedScrollTime ث', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _isAppBlocked ? AppColors.danger : Colors.white)),
              ],
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(_isAppBlocked ? AppColors.danger : AppColors.success),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: _buildCameraContent(),
      ),
    );
  }

  Widget _buildCameraContent() {
    if (!_isCameraInitialized || controller == null) {
      return const Center(child: CircularProgressIndicator());
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
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(36), topRight: Radius.circular(36)),
      ),
      child: Column(
        children: [
          Text('إجمالي السكوات: $squatsCount', style: const TextStyle(fontSize: 22, color: Colors.white)),
        ],
      ),
    );
  }

  _InputImageResult? _inputImageFromCameraImage(CameraImage image) {
    final cam = controller;
    if (cam == null) return null;
    final camera = cam.description;

    InputImageRotation? rotation;
    if (Platform.isAndroid) {
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
    for (final plane in image.planes) { allBytes.putUint8List(plane.bytes); }
    final bytes = allBytes.done().buffer.asUint8List();
    final rawSize = Size(image.width.toDouble(), image.height.toDouble());
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(size: rawSize, rotation: rotation, format: format, bytesPerRow: image.planes[0].bytesPerRow),
    );
    final isRotated = rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg;
    return _InputImageResult(inputImage: inputImage, adjustedSize: isRotated ? Size(rawSize.height, rawSize.width) : rawSize);
  }
}

class _InputImageResult {
  final InputImage inputImage;
  final Size adjustedSize;
  const _InputImageResult({required this.inputImage, required this.adjustedSize});
}

class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width == 0 || imageSize.height == 0) return;
    final paint = Paint()..color = const Color(0xff00f0ff)..strokeWidth = 4.0..style = PaintingStyle.stroke;
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset scalePoint(PoseLandmark landmark) => Offset(landmark.x * scaleX, landmark.y * scaleY);

    void drawLine(PoseLandmarkType t1, PoseLandmarkType t2) {
      final lm1 = pose.landmarks[t1];
      final lm2 = pose.landmarks[t2];
      if (lm1 != null && lm2 != null && lm1.likelihood > 0.5 && lm2.likelihood > 0.5) {
        canvas.drawLine(scalePoint(lm1), scalePoint(lm2), paint);
      }
    }
    
    drawLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    drawLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    drawLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    drawLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) => oldDelegate.pose != pose;
}
