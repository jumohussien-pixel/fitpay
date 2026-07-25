import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// THEME & CONSTANTS
// =============================================================================

abstract final class PushBlockColors {
  static const Color background = Color(0xFF0F172A);
  static const Color emerald = Color(0xFF10B981);
  static const Color coral = Color(0xFFEF4444);
  static const Color hudPanel = Color(0xCC0F172A);
  static const Color border = Color(0x6610B981);
  static const Color textMuted = Color(0xFF94A3B8);
}

abstract final class PushBlockConstants {
  static const double downAngleThreshold = 90.0;
  static const double upAngleThreshold = 160.0;
  static const Duration calibrationDuration = Duration(seconds: 3);
  static const Duration repDebounce = Duration(milliseconds: 450);
  static const double landmarkLikelihoodMin = 0.5;
  static const double symmetryToleranceDeg = 22.0;
  static const double emaAlpha = 0.35;
  static const int defaultSessionGoal = 10;
  static const String sessionGoalKey = 'pushblock_session_goal';
}

enum ExercisePhase { calibrating, up, down, noPose }

enum CameraPermissionStatus { unknown, granted, denied, error }

// =============================================================================
// ENTRY POINT
// =============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PushBlockApp());
}

class PushBlockApp extends StatelessWidget {
  const PushBlockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PushBlock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: PushBlockColors.background,
        colorScheme: const ColorScheme.dark(
          primary: PushBlockColors.emerald,
          secondary: PushBlockColors.emerald,
          error: PushBlockColors.coral,
          surface: PushBlockColors.background,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const PushBlockScreen(),
    );
  }
}

// =============================================================================
// BIOMECHANICS & SMOOTHING
// =============================================================================

class SmoothPoint {
  double x;
  double y;
  double z;

  SmoothPoint(this.x, this.y, this.z);
}

class LandmarkSmoother {
  final Map<PoseLandmarkType, SmoothPoint> _cache = {};
  final double alpha;

  LandmarkSmoother({this.alpha = PushBlockConstants.emaAlpha});

  void reset() => _cache.clear();

  PoseLandmark? smooth(PoseLandmark? raw) {
    if (raw == null) return null;
    final cached = _cache[raw.type];
    if (cached == null) {
      _cache[raw.type] = SmoothPoint(raw.x, raw.y, raw.z);
      return raw;
    }
    cached.x = alpha * raw.x + (1 - alpha) * cached.x;
    cached.y = alpha * raw.y + (1 - alpha) * cached.y;
    cached.z = alpha * raw.z + (1 - alpha) * cached.z;
    return PoseLandmark(
      type: raw.type,
      x: cached.x,
      y: cached.y,
      z: cached.z,
      likelihood: raw.likelihood,
    );
  }
}

double elbowAngle3D(PoseLandmark shoulder, PoseLandmark elbow, PoseLandmark wrist) {
  final ax = shoulder.x - elbow.x;
  final ay = shoulder.y - elbow.y;
  final az = shoulder.z - elbow.z;
  final bx = wrist.x - elbow.x;
  final by = wrist.y - elbow.y;
  final bz = wrist.z - elbow.z;

  final dot = ax * bx + ay * by + az * bz;
  final magA = math.sqrt(ax * ax + ay * ay + az * az);
  final magB = math.sqrt(bx * bx + by * by + bz * bz);
  if (magA == 0 || magB == 0) return 180.0;

  final cosTheta = (dot / (magA * magB)).clamp(-1.0, 1.0);
  return math.acos(cosTheta) * 180.0 / math.pi;
}

bool _landmarkUsable(PoseLandmark? landmark) {
  return landmark != null &&
      landmark.likelihood >= PushBlockConstants.landmarkLikelihoodMin;
}

// =============================================================================
// REP COUNTING ENGINE
// =============================================================================

class PushUpRepEngine {
  PushUpRepEngine();

  final LandmarkSmoother _smoother = LandmarkSmoother();

  ExercisePhase phase = ExercisePhase.calibrating;
  int repCount = 0;
  String feedback = 'Hold starting position — calibrating…';

  DateTime? _calibrationStartedAt;
  DateTime? _lastRepAt;
  bool _validDownAchieved = false;
  double _calibratedExtension = PushBlockConstants.upAngleThreshold;
  final List<double> _calibrationSamples = [];

  double get upThreshold =>
      math.max(PushBlockConstants.upAngleThreshold, _calibratedExtension - 8.0);

  void resetSession() {
    _smoother.reset();
    phase = ExercisePhase.calibrating;
    repCount = 0;
    feedback = 'Hold starting position — calibrating…';
    _calibrationStartedAt = null;
    _lastRepAt = null;
    _validDownAchieved = false;
    _calibratedExtension = PushBlockConstants.upAngleThreshold;
    _calibrationSamples.clear();
  }

  void processPose(Pose pose) {
    final leftShoulder = _smoother.smooth(pose.landmarks[PoseLandmarkType.leftShoulder]);
    final leftElbow = _smoother.smooth(pose.landmarks[PoseLandmarkType.leftElbow]);
    final leftWrist = _smoother.smooth(pose.landmarks[PoseLandmarkType.leftWrist]);
    final rightShoulder = _smoother.smooth(pose.landmarks[PoseLandmarkType.rightShoulder]);
    final rightElbow = _smoother.smooth(pose.landmarks[PoseLandmarkType.rightElbow]);
    final rightWrist = _smoother.smooth(pose.landmarks[PoseLandmarkType.rightWrist]);

    final leftReady = _landmarkUsable(leftShoulder) &&
        _landmarkUsable(leftElbow) &&
        _landmarkUsable(leftWrist);
    final rightReady = _landmarkUsable(rightShoulder) &&
        _landmarkUsable(rightElbow) &&
        _landmarkUsable(rightWrist);

    if (!leftReady && !rightReady) {
      phase = ExercisePhase.noPose;
      feedback = 'Step into frame — show your upper body';
      return;
    }

    if (!leftReady || !rightReady) {
      phase = ExercisePhase.noPose;
      feedback = 'Both arms must stay visible';
      return;
    }

    final leftAngle = elbowAngle3D(leftShoulder!, leftElbow!, leftWrist!);
    final rightAngle = elbowAngle3D(rightShoulder!, rightElbow!, rightWrist!);
    final avgAngle = (leftAngle + rightAngle) / 2.0;
    final asymmetry = (leftAngle - rightAngle).abs();

    _calibrationStartedAt ??= DateTime.now();
    final calibrating = DateTime.now().difference(_calibrationStartedAt!) <
        PushBlockConstants.calibrationDuration;

    if (calibrating) {
      phase = ExercisePhase.calibrating;
      _calibrationSamples.add(avgAngle);
      final remaining = PushBlockConstants.calibrationDuration -
          DateTime.now().difference(_calibrationStartedAt!);
      feedback =
          'Calibrating… ${remaining.inSeconds + 1}s — hold extended plank';
      return;
    }

    if (_calibrationSamples.isNotEmpty) {
      _calibratedExtension = _calibrationSamples.reduce(math.max);
    }

    final bothDown = leftAngle < PushBlockConstants.downAngleThreshold &&
        rightAngle < PushBlockConstants.downAngleThreshold;
    final bothUp = leftAngle > upThreshold && rightAngle > upThreshold;

    if (bothDown) {
      if (asymmetry <= PushBlockConstants.symmetryToleranceDeg) {
        if (phase != ExercisePhase.down) {
          phase = ExercisePhase.down;
          _validDownAchieved = true;
          feedback = 'Good depth — push back up!';
        }
      } else {
        phase = ExercisePhase.down;
        _validDownAchieved = false;
        feedback = 'Keep arms even — match depth on both sides';
      }
      return;
    }

    if (leftAngle < PushBlockConstants.downAngleThreshold ||
        rightAngle < PushBlockConstants.downAngleThreshold) {
      phase = ExercisePhase.up;
      _validDownAchieved = false;
      feedback = asymmetry > PushBlockConstants.symmetryToleranceDeg
          ? 'Keep arms even'
          : 'Go lower — both elbows below 90°';
      return;
    }

    if (bothUp) {
      if (phase == ExercisePhase.down && _validDownAchieved) {
        final now = DateTime.now();
        if (_lastRepAt == null ||
            now.difference(_lastRepAt!) >= PushBlockConstants.repDebounce) {
          repCount++;
          _lastRepAt = now;
          feedback = 'Good Rep!';
        } else {
          feedback = 'Push up fully!';
        }
      } else {
        feedback = phase == ExercisePhase.down ? 'Push up fully!' : 'Ready — go down';
      }
      phase = ExercisePhase.up;
      _validDownAchieved = false;
      return;
    }

    phase = ExercisePhase.up;
    feedback = 'Go lower';
  }
}

// =============================================================================
// CAMERA → ML KIT INPUT IMAGE
// =============================================================================

InputImageRotation _rotationFromCamera(CameraDescription camera) {
  final sensorOrientation = camera.sensorOrientation;
  if (Platform.isIOS) {
    return InputImageRotationValue.fromRawValue(sensorOrientation) ??
        InputImageRotation.rotation0deg;
  }
  switch (sensorOrientation) {
    case 90:
      return InputImageRotation.rotation90deg;
    case 180:
      return InputImageRotation.rotation180deg;
    case 270:
      return InputImageRotation.rotation270deg;
    default:
      return InputImageRotation.rotation0deg;
  }
}

Uint8List _yuv420ToNv21(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final nv21 = Uint8List(width * height + (width * height ~/ 2));
  var offset = 0;

  for (var row = 0; row < height; row++) {
    final rowStart = row * yPlane.bytesPerRow;
    nv21.setRange(offset, offset + width, yPlane.bytes, rowStart);
    offset += width;
  }

  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  for (var row = 0; row < height ~/ 2; row++) {
    for (var col = 0; col < width ~/ 2; col++) {
      final uvIndex = row * uvRowStride + col * uvPixelStride;
      nv21[offset++] = vPlane.bytes[uvIndex];
      nv21[offset++] = uPlane.bytes[uvIndex];
    }
  }

  return nv21;
}

InputImage? inputImageFromCameraImage(
  CameraImage image,
  CameraDescription camera,
) {
  final rotation = _rotationFromCamera(camera);
  final format = InputImageFormatValue.fromRawValue(image.format.raw);

  if (format == null) return null;

  if (Platform.isAndroid) {
    if (format == InputImageFormat.nv21) {
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    }

    if (format == InputImageFormat.yuv420 ||
        format == InputImageFormat.yuv_420_888) {
      return InputImage.fromBytes(
        bytes: _yuv420ToNv21(image),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    }
  }

  if (Platform.isIOS && format == InputImageFormat.bgra8888) {
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.bgra8888,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  return null;
}

// =============================================================================
// POSE SKELETON PAINTER
// =============================================================================

class PoseSkeletonPainter extends CustomPainter {
  PoseSkeletonPainter({
    required this.landmarks,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  final Map<PoseLandmarkType, PoseLandmark> landmarks;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  static const _jointTypes = [
    PoseLandmarkType.leftShoulder,
    PoseLandmarkType.rightShoulder,
    PoseLandmarkType.leftElbow,
    PoseLandmarkType.rightElbow,
    PoseLandmarkType.leftWrist,
    PoseLandmarkType.rightWrist,
  ];

  static const _bones = [
    (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow),
    (PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist),
    (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow),
    (PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist),
    (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
  ];

  Offset _translate(double x, double y, Size canvasSize) {
    double translatedX = x;
    double translatedY = y;
    double imageW = imageSize.width;
    double imageH = imageSize.height;

    switch (rotation) {
      case InputImageRotation.rotation90deg:
        translatedX = y;
        translatedY = imageSize.height - x;
        imageW = imageSize.height;
        imageH = imageSize.width;
        break;
      case InputImageRotation.rotation180deg:
        translatedX = imageSize.width - x;
        translatedY = imageSize.height - y;
        break;
      case InputImageRotation.rotation270deg:
        translatedX = imageSize.width - y;
        translatedY = x;
        imageW = imageSize.height;
        imageH = imageSize.width;
        break;
      case InputImageRotation.rotation0deg:
        break;
    }

    if (cameraLensDirection == CameraLensDirection.front) {
      translatedX = imageW - translatedX;
    }

    final scaleX = canvasSize.width / imageW;
    final scaleY = canvasSize.height / imageH;
    final scale = math.max(scaleX, scaleY);

    final offsetX = (canvasSize.width - imageW * scale) / 2;
    final offsetY = (canvasSize.height - imageH * scale) / 2;

    return Offset(
      translatedX * scale + offsetX,
      translatedY * scale + offsetY,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bonePaint = Paint()
      ..color = PushBlockColors.emerald.withOpacity( 0.85)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final jointPaint = Paint()
      ..color = PushBlockColors.emerald
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = PushBlockColors.emerald.withOpacity( 0.25)
      ..style = PaintingStyle.fill;

    for (final (a, b) in _bones) {
      final la = landmarks[a];
      final lb = landmarks[b];
      if (!_landmarkUsable(la) || !_landmarkUsable(lb)) continue;
      canvas.drawLine(
        _translate(la!.x, la.y, size),
        _translate(lb!.x, lb.y, size),
        bonePaint,
      );
    }

    for (final type in _jointTypes) {
      final lm = landmarks[type];
      if (!_landmarkUsable(lm)) continue;
      final center = _translate(lm!.x, lm.y, size);
      canvas.drawCircle(center, 12, glowPaint);
      canvas.drawCircle(center, 6, jointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PoseSkeletonPainter oldDelegate) {
    return oldDelegate.landmarks != landmarks ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}

// =============================================================================
// MAIN SCREEN
// =============================================================================

class PushBlockScreen extends StatefulWidget {
  const PushBlockScreen({super.key});

  @override
  State<PushBlockScreen> createState() => _PushBlockScreenState();
}

class _PushBlockScreenState extends State<PushBlockScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  late final PoseDetector _poseDetector;
  final PushUpRepEngine _repEngine = PushUpRepEngine();

  bool _isProcessing = false;
  bool _isBusy = false;
  CameraPermissionStatus _permissionStatus = CameraPermissionStatus.unknown;
  String? _cameraError;

  Map<PoseLandmarkType, PoseLandmark> _visibleLandmarks = {};
  Size _imageSize = Size.zero;
  InputImageRotation _imageRotation = InputImageRotation.rotation0deg;

  int _sessionGoal = PushBlockConstants.defaultSessionGoal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _loadSessionGoal();
    await _initializeCamera();
  }

  Future<void> _loadSessionGoal() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sessionGoal =
          prefs.getInt(PushBlockConstants.sessionGoalKey) ??
              PushBlockConstants.defaultSessionGoal;
    });
  }

  Future<void> _initializeCamera() async {
    setState(() {
      _cameraError = null;
      _permissionStatus = CameraPermissionStatus.unknown;
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _cameraError = 'No camera found on this device';
          _permissionStatus = CameraPermissionStatus.error;
        });
        return;
      }

      if (_cameraIndex >= _cameras.length) _cameraIndex = 0;
      await _startCamera(_cameras[_cameraIndex]);
    } on CameraException catch (e) {
      setState(() {
        _cameraError = e.description ?? 'Camera unavailable';
        _permissionStatus = e.code == 'CameraAccessDenied'
            ? CameraPermissionStatus.denied
            : CameraPermissionStatus.error;
      });
    } catch (e) {
      setState(() {
        _cameraError = e.toString();
        _permissionStatus = CameraPermissionStatus.error;
      });
    }
  }

  Future<void> _startCamera(CameraDescription camera) async {
    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }

    _repEngine.resetSession();
    _imageRotation = _rotationFromCamera(camera);

    setState(() {
      _cameraController = controller;
      _permissionStatus = CameraPermissionStatus.granted;
      _cameraError = null;
    });

    await controller.startImageStream(_onCameraFrame);
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isBusy) return;
    _isBusy = true;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    try {
      await _startCamera(_cameras[_cameraIndex]);
    } finally {
      _isBusy = false;
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (_isProcessing || !mounted) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isStreamingImages) return;

    _isProcessing = true;
    try {
      final inputImage = inputImageFromCameraImage(image, controller.description);
      if (inputImage == null) return;

      _imageSize = inputImage.metadata?.size ?? Size.zero;
      final poses = await _poseDetector.processImage(inputImage);
      if (!mounted) return;

      if (poses.isEmpty) {
        _repEngine.phase = ExercisePhase.noPose;
        _repEngine.feedback = 'Step into frame — show your upper body';
        setState(() => _visibleLandmarks = {});
        return;
      }

      final pose = poses.first;
      _repEngine.processPose(pose);

      setState(() {
        _visibleLandmarks = Map.fromEntries(
          pose.landmarks.entries.where(
            (e) => _landmarkUsable(e.value),
          ),
        );
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cameraError = 'Pose processing failed';
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(controller.stopImageStream());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cameraController?.stopImageStream());
    unawaited(_cameraController?.dispose());
    unawaited(_poseDetector.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PushBlockColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraLayer(),
          _buildScanlineOverlay(),
          _buildSkeletonOverlay(),
          _buildTopBar(),
          _buildBottomHud(),
          if (_cameraError != null) _buildErrorOverlay(),
        ],
      ),
    );
  }

  Widget _buildCameraLayer() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        color: PushBlockColors.background,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: PushBlockColors.emerald),
            const SizedBox(height: 16),
            Text(
              _permissionStatus == CameraPermissionStatus.denied
                  ? 'Camera permission required'
                  : 'Initializing camera…',
              style: const TextStyle(color: PushBlockColors.textMuted),
            ),
          ],
        ),
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.previewSize?.height ?? 1,
        height: controller.value.previewSize?.width ?? 1,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _buildScanlineOverlay() {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              PushBlockColors.background.withOpacity( 0.35),
              Colors.transparent,
              PushBlockColors.background.withOpacity( 0.55),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkeletonOverlay() {
    if (_visibleLandmarks.isEmpty || _imageSize == Size.zero) {
      return const SizedBox.shrink();
    }

    return CustomPaint(
      painter: PoseSkeletonPainter(
        landmarks: _visibleLandmarks,
        imageSize: _imageSize,
        rotation: _imageRotation,
        cameraLensDirection:
            _cameraController?.description.lensDirection ??
                CameraLensDirection.front,
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: [
            _HudChip(
              label: 'PushBlock',
              icon: Icons.shield_outlined,
              accent: PushBlockColors.emerald,
            ),
            const Spacer(),
            _PermissionBadge(status: _permissionStatus),
            const SizedBox(width: 8),
            _IconHudButton(
              icon: Icons.cameraswitch_rounded,
              tooltip: 'Switch camera',
              onPressed: _cameras.length > 1 ? _switchCamera : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomHud() {
    final progress = (_repEngine.repCount / _sessionGoal).clamp(0.0, 1.0);
    final phaseLabel = switch (_repEngine.phase) {
      ExercisePhase.calibrating => 'CALIBRATING',
      ExercisePhase.down => 'DOWN',
      ExercisePhase.up => 'UP',
      ExercisePhase.noPose => 'NO POSE',
    };
    final phaseColor = switch (_repEngine.phase) {
      ExercisePhase.calibrating => PushBlockColors.textMuted,
      ExercisePhase.down => PushBlockColors.coral,
      ExercisePhase.up => PushBlockColors.emerald,
      ExercisePhase.noPose => PushBlockColors.coral,
    };

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: PushBlockColors.hudPanel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: PushBlockColors.border, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: PushBlockColors.emerald.withOpacity( 0.12),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${_repEngine.repCount}',
                    style: const TextStyle(
                      fontSize: 72,
                      fontWeight: FontWeight.w800,
                      height: 0.9,
                      color: PushBlockColors.emerald,
                      letterSpacing: -2,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 10),
                    child: Text(
                      'REPS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: PushBlockColors.textMuted,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        phaseLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.6,
                          color: phaseColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Goal $_sessionGoal',
                        style: const TextStyle(
                          fontSize: 12,
                          color: PushBlockColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: PushBlockColors.background,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    progress >= 1.0
                        ? PushBlockColors.emerald
                        : PushBlockColors.emerald.withOpacity( 0.85),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _repEngine.feedback,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _repEngine.feedback == 'Good Rep!'
                      ? PushBlockColors.emerald
                      : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Container(
      color: PushBlockColors.background.withOpacity( 0.88),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_rounded,
              color: PushBlockColors.coral, size: 48),
          const SizedBox(height: 16),
          Text(
            _cameraError ?? 'Camera error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _initializeCamera,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
            style: FilledButton.styleFrom(
              backgroundColor: PushBlockColors.emerald,
              foregroundColor: PushBlockColors.background,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HUD WIDGETS
// =============================================================================

class _HudChip extends StatelessWidget {
  const _HudChip({
    required this.label,
    required this.icon,
    required this.accent,
  });

  final String label;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: PushBlockColors.hudPanel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withOpacity( 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionBadge extends StatelessWidget {
  const _PermissionBadge({required this.status});

  final CameraPermissionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      CameraPermissionStatus.granted => (
          'LIVE',
          PushBlockColors.emerald,
          Icons.fiber_manual_record_rounded,
        ),
      CameraPermissionStatus.denied => (
          'DENIED',
          PushBlockColors.coral,
          Icons.block_rounded,
        ),
      CameraPermissionStatus.error => (
          'ERROR',
          PushBlockColors.coral,
          Icons.error_outline_rounded,
        ),
      CameraPermissionStatus.unknown => (
          'INIT',
          PushBlockColors.textMuted,
          Icons.hourglass_empty_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: PushBlockColors.hudPanel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity( 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconHudButton extends StatelessWidget {
  const _IconHudButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PushBlockColors.hudPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PushBlockColors.border),
      ),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: PushBlockColors.emerald),
      ),
    );
  }
}
