import 'dart:async';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FitPayApp());
}

class FitPayApp extends StatelessWidget {
  const FitPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FITPAY',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          surface: Colors.black,
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    SquatCameraScreen(),
    WalkScreen(),
    StoreScreen(),
    ProgressScreen(),
    AppBlockerScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.black,
          border: Border(
            top: BorderSide(color: Colors.white24, width: 1),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: Colors.black,
          elevation: 0,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white38,
          type: BottomNavigationBarType.fixed,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.camera_alt_outlined),
              activeIcon: Icon(Icons.camera_alt),
              label: 'Camera',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.near_me_outlined),
              activeIcon: Icon(Icons.near_me),
              label: 'Walk',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.shopping_bag_outlined),
              activeIcon: Icon(Icons.shopping_bag),
              label: 'Store',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart),
              label: 'Progress',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.phonelink_setup_outlined),
              activeIcon: Icon(Icons.phonelink_setup),
              label: 'Blocker',
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// HOME SCREEN (Exact UI from your screenshot)
// ==========================================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'FITPAY',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                    color: Colors.white,
                  ),
                ),
                Row(
                  children: [
                    _buildOutlineButton(
                      child: const Icon(Icons.wb_sunny_outlined, size: 20, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    _buildOutlineButton(
                      child: const Row(
                        children: [
                          Icon(Icons.bolt_outlined, size: 18, color: Colors.white),
                          SizedBox(width: 4),
                          Text('0', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Screen Time Expired Card
            _buildOutlinedCard(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.access_time_outlined, color: Colors.white70, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'SCREEN TIME EXPIRED',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    child: const Text('CONVERT', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Time's up Card
            _buildOutlinedCard(
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.camera_alt_outlined, color: Colors.black, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Time's up — earn more",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Visit the Camera tab to do squats. Convert credits to unlock screen time.',
                          style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Go for a Walk Card
            _buildOutlinedCard(
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.near_me_outlined, color: Colors.black, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Go for a Walk",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Track distance with GPS · 3 difficulty levels',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Stats Cards
            Row(
              children: [
                Expanded(
                  child: _buildOutlinedCard(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: const Column(
                      children: [
                        Icon(Icons.show_chart_rounded, color: Colors.white70, size: 22),
                        SizedBox(height: 6),
                        Text('0', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
                        SizedBox(height: 4),
                        Text('SQUATS', style: TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 1.5)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOutlinedCard(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: const Column(
                      children: [
                        Icon(Icons.bolt_outlined, color: Colors.white70, size: 22),
                        SizedBox(height: 6),
                        Text('0', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
                        SizedBox(height: 4),
                        Text('CREDITS', style: TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 1.5)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _buildOutlinedCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white30, width: 1),
      ),
      child: child,
    );
  }

  static Widget _buildOutlineButton({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white30, width: 1),
      ),
      child: child,
    );
  }
}

// ==========================================
// CAMERA / SQUAT DETECTOR SCREEN
// ==========================================
class SquatCameraScreen extends StatefulWidget {
  const SquatCameraScreen({super.key});

  @override
  State<SquatCameraScreen> createState() => _SquatCameraScreenState();
}

class _SquatCameraScreenState extends State<SquatCameraScreen> {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isProcessing = false;

  late final PoseDetector _poseDetector;
  int _squatCount = 0;
  bool _isSquattingDown = false;

  @override
  void initState() {
    super.initState();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        mode: PoseDetectionMode.stream,
        model: PoseDetectionModel.accurate,
      ),
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;

    _cameraController = CameraController(
      _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      ),
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream((image) {
      if (_isProcessing) return;
      _isProcessing = true;
      _processPose(image);
    });
    setState(() {});
  }

  Future<void> _processPose(CameraImage image) async {
    try {
      final inputImage = InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation270deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );

      final poses = await _poseDetector.processImage(inputImage);
      if (poses.isNotEmpty) {
        _detectSquats(poses.first);
      }
    } catch (_) {
    } finally {
      _isProcessing = false;
    }
  }

  void _detectSquats(Pose pose) {
    final hip = pose.landmarks[PoseLandmarkType.rightHip] ?? pose.landmarks[PoseLandmarkType.leftHip];
    final knee = pose.landmarks[PoseLandmarkType.rightKnee] ?? pose.landmarks[PoseLandmarkType.leftKnee];
    final ankle = pose.landmarks[PoseLandmarkType.rightAnkle] ?? pose.landmarks[PoseLandmarkType.leftAnkle];

    if (hip == null || knee == null || ankle == null) return;

    final double radians = math.atan2(ankle.y - knee.y, ankle.x - knee.x) - math.atan2(hip.y - knee.y, hip.x - knee.x);
    double angle = radians.abs() * (180.0 / math.pi);
    if (angle > 180.0) angle = 360.0 - angle;

    if (angle <= 100.0 && !_isSquattingDown) {
      _isSquattingDown = true;
    }
    if (angle >= 160.0 && _isSquattingDown) {
      _isSquattingDown = false;
      setState(() {
        _squatCount++;
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraController != null && _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!)
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white30),
              ),
              child: Text(
                'Squats: $_squatCount',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          )
        ],
      ),
    );
  }
}

// OTHER TAB SCREENS
class WalkScreen extends StatelessWidget {
  const WalkScreen({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Text('Walk Screen (Coming Soon)', style: TextStyle(color: Colors.white)));
}

class StoreScreen extends StatelessWidget {
  const StoreScreen({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Text('Store Screen', style: TextStyle(color: Colors.white)));
}

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Text('Progress Screen', style: TextStyle(color: Colors.white)));
}

class AppBlockerScreen extends StatelessWidget {
  const AppBlockerScreen({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Text('App Blocker Screen', style: TextStyle(color: Colors.white)));
}
