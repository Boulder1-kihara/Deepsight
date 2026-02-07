// lib/main.dart
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'deep_sight_manager.dart';

Future<void> main() async {
  // 1. Critical Bindings
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Load Environment Variables
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint(
        "Warning: .env file not found. Using fallback or expecting hardcoded key.");
  }

  // 3. Lock Orientation (Prevents camera re-init crashes on rotation)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const DeepSightApp());
}

class DeepSightApp extends StatelessWidget {
  const DeepSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DeepSight AI',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.blueAccent,
          secondary: Colors.amber,
          error: Colors.redAccent,
        ),
      ),
      home: const DeepSightScreen(),
    );
  }
}

class DeepSightScreen extends StatefulWidget {
  const DeepSightScreen({super.key});

  @override
  State<DeepSightScreen> createState() => _DeepSightScreenState();
}

class _DeepSightScreenState extends State<DeepSightScreen>
    with WidgetsBindingObserver {
  final DeepSightManager _manager = DeepSightManager();
  final FlutterTts _flutterTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  Timer? _scanTimer;
  bool _isDanger = false;
  bool _userInitiated = false;
  DateTime _lastSpoken = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSystem();
  }

  Future<void> _initializeSystem() async {
    // Manager Initialization
    final apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
    await _manager.initialize(apiKey);
    setState(() {}); // Refresh UI
  }

  void _startScanning() {
    if (_scanTimer != null && _scanTimer!.isActive) return;

    // Scan every 2.5 seconds
    _scanTimer =
        Timer.periodic(const Duration(milliseconds: 2500), (timer) async {
      if (_manager.status == DeepSightStatus.ready && _userInitiated) {
        await _manager.analyzeFrame();
        _processAdvice(_manager.advice);
      }
    });
  }

  Future<void> _enableSystem() async {
    setState(() => _userInitiated = true);

    // Web Audio Unlock
    try {
      if (kIsWeb) {
        // Dummy speech to unlock
        await _flutterTts.speak(" ");
      }
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.awaitSpeakCompletion(true);

      await _flutterTts.speak("DeepSight Active");
    } catch (e) {
      debugPrint("TTS init error: $e");
    }

    _startScanning();
  }

  Future<void> _processAdvice(String advice) async {
    if (advice.contains("Initializing") || advice.contains("Retrying")) return;

    // Logic to determine danger
    final bool danger = advice.toUpperCase().contains("DANGER") ||
        advice.toUpperCase().contains("CAUTION");

    setState(() => _isDanger = danger);

    // Audio Feedback Logic
    if (danger) {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 500, 200, 500]); // SOS-like pattern
      }
      // Play beep using AssetSource
      try {
        await _audioPlayer.play(AssetSource('beep.mp3'),
            mode: PlayerMode.lowLatency);
      } catch (e) {
        debugPrint("Audio Error: $e");
      }
    }

    // TTS Debounce (Don't repeat too often)
    if (DateTime.now().difference(_lastSpoken).inSeconds > 2 || danger) {
      _lastSpoken = DateTime.now();
      String cleanText = advice
          .replaceAll("[", "")
          .replaceAll("]", "")
          .replaceAll(":", " is ");
      await _flutterTts.speak(cleanText);
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _manager.disposeResources();
    _flutterTts.stop();
    _audioPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Lifecycle handling to pause/resume camera usage
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_manager.cameraController == null ||
        !_manager.cameraController!.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _manager.cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _manager.initialize(dotenv.env['GEMINI_API_KEY'] ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _manager,
        builder: (context, child) {
          // 1. Loading State
          if (_manager.status == DeepSightStatus.initializing) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text("Initializing DeepSight...",
                      style: TextStyle(color: Colors.white)),
                ],
              ),
            );
          }

          // 2. Camera Failure State (Fallback UI)
          if (_manager.status == DeepSightStatus.cameraFailure) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline,
                      size: 60, color: Colors.amber),
                  const SizedBox(height: 20),
                  Text(_manager.advice),
                  ElevatedButton(
                    onPressed: () => _initializeSystem(),
                    child: const Text("Retry Initialization"),
                  )
                ],
              ),
            );
          }

          // 3. Active State
          return Stack(
            fit: StackFit.expand,
            children: [
              // Camera Preview
              if (_manager.cameraController != null &&
                  _manager.cameraController!.value.isInitialized)
                CameraPreview(_manager.cameraController!),

              // Danger Overlay
              if (_isDanger) Container(color: Colors.red.withOpacity(0.3)),

              // Info Overlay
              Positioned(
                bottom: 50,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _isDanger ? Colors.red : Colors.blueAccent),
                  ),
                  child: Text(
                    _manager.advice,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

              // Start Button Overlay (For User Interaction)
              if (!_userInitiated && _manager.status == DeepSightStatus.ready)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: ElevatedButton.icon(
                      onPressed: _enableSystem,
                      icon: const Icon(Icons.power_settings_new),
                      label: const Text("START DEEPSIGHT"),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 20),
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
