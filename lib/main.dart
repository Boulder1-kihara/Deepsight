import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Warning: .env file missing: $e");
  }
  try {
    cameras = await availableCameras();
  } catch (e) {
    cameras = [];
  }
  runApp(const DeepSightApp());
}

class DeepSightApp extends StatelessWidget {
  const DeepSightApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DeepSight AI',
      theme: ThemeData.dark(),
      home: const DeepSightScreen(),
    );
  }
}

class DeepSightScreen extends StatefulWidget {
  const DeepSightScreen({super.key});
  @override
  State<DeepSightScreen> createState() => _DeepSightScreenState();
}

class _DeepSightScreenState extends State<DeepSightScreen> {
  late CameraController _cameraController;
  GenerativeModel? _model;
  final FlutterTts _flutterTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _isBatterySaver = false;
  String _currentAdvice = "Initializing DeepSight...";
  String _lastSpokenAdvice = "";
  Timer? _beepTimer;

  bool get _isDanger => _currentAdvice.toUpperCase().contains("DANGER");

  // System Instructions to be injected into the prompt
  final String _systemInstruction = """
  You are a Spatial Safety Assistant for the blind. 
  Detect holes, drops, or obstacles. Estimate distance in steps or meters.
  Format strictly as: [DANGER_LEVEL] : [Direction] - [Distance]
  """;

  @override
  void initState() {
    super.initState();
    _initializeGemini();
    _initializeTTS();
    _initializeCamera();
  }

  void _initializeGemini() {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) return;

    _model = GenerativeModel(
      // Using the fully qualified stable model name for V1
      model: 'gemini-1.5-flash-latest', 
      apiKey: apiKey,
      // Removed systemInstruction to fix "Unknown name" error
      requestOptions: const RequestOptions(apiVersion: 'v1'),
    );
  }

  void _initializeTTS() {
    _flutterTts.setLanguage("en-US");
    _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;
    _cameraController = CameraController(cameras[0], ResolutionPreset.medium, enableAudio: false);
    try {
      await _cameraController.initialize();
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
      _analyzeFrame();
    } catch (e) {
      debugPrint("Camera error: $e");
    }
  }

  Future<void> _analyzeFrame() async {
    if (!mounted || !_isCameraInitialized || _isProcessing) return;
    if (_model == null) return;

    setState(() => _isProcessing = true);

    try {
      final XFile imageFile = await _cameraController.takePicture();
      final Uint8List imageBytes = await imageFile.readAsBytes();

      final content = [
        Content.multi([
          // Injecting instructions directly into the message for V1 Stable
          TextPart("INSTRUCTION: $_systemInstruction\n" 
                   "USER REQUEST: Analyze ground safety. Mention holes and distance."),
          DataPart('image/jpeg', imageBytes),
        ])
      ];

      final response = await _model!.generateContent(content).timeout(const Duration(seconds: 5));
      final text = response.text ?? "SAFE : Path clear";

      if (mounted) {
        setState(() => _currentAdvice = text);
        await _speak(text);
      }
    } catch (e) {
      debugPrint("API Error: $e"); 
      setState(() => _currentAdvice = "CAUTION : Scanning...");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
        // Delay to prevent 429 rate limit errors
        await Future.delayed(Duration(milliseconds: _isBatterySaver ? 4000 : 1500));
        _analyzeFrame();
      }
    }
  }

  void _startBeeping(String text) {
    _beepTimer?.cancel();
    if (!text.toUpperCase().contains("DANGER")) return;

    int ms = 1000;
    if (text.contains("1 step")) ms = 250;
    else if (text.contains("2 step")) ms = 500;

    _beepTimer = Timer.periodic(Duration(milliseconds: ms), (timer) {
      _audioPlayer.play(AssetSource('beep.mp3'));
      Future.delayed(const Duration(seconds: 2), () => timer.cancel());
    });
  }

  Future<void> _speak(String text) async {
    if (text == _lastSpokenAdvice) return;
    _lastSpokenAdvice = text;

    _startBeeping(text);
    String cleanText = text.replaceAll("[", "").replaceAll("]", "").replaceAll(":", ".");

    if (text.toUpperCase().contains("DANGER")) {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 500, 200, 500]);
      }
    }

    await _flutterTts.stop();
    await _flutterTts.speak(cleanText);
  }

  void _triggerDemoHole() {
    const simulated = "DANGER : Hole Ahead - 2 steps.";
    setState(() => _currentAdvice = simulated);
    _speak(simulated);
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _flutterTts.stop();
    _audioPlayer.dispose();
    _beepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      body: Stack(
        children: [
          SizedBox.expand(child: CameraPreview(_cameraController)),
          if (_isDanger) IgnorePointer(child: Container(color: Colors.red.withOpacity(0.4))),
          
          Positioned(
            top: 50,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton.icon(
                  onPressed: _triggerDemoHole,
                  icon: const Icon(Icons.warning_amber),
                  label: const Text("Demo Hole"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                ),
                const SizedBox(height: 10),
                FilterChip(
                  label: const Text("Battery Saver"),
                  selected: _isBatterySaver,
                  onSelected: (val) => setState(() => _isBatterySaver = val),
                ),
              ],
            ),
          ),

          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: _isDanger ? Colors.red : Colors.yellowAccent, width: 3),
              ),
              child: Text(
                _currentAdvice,
                style: TextStyle(color: _isDanger ? Colors.redAccent : Colors.yellowAccent, fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}