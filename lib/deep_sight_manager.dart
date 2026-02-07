// lib/deep_sight_manager.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter/foundation.dart';

enum DeepSightStatus {
  initializing,
  ready,
  error,
  processing,
  cameraFailure, // Specific state for camera issues allowing UI fallback
}

class DeepSightManager extends ChangeNotifier {
  static final DeepSightManager _instance = DeepSightManager._internal();
  factory DeepSightManager() => _instance;
  DeepSightManager._internal();

  // Observable State
  DeepSightStatus _status = DeepSightStatus.initializing;
  DeepSightStatus get status => _status;

  String _advice = "Initializing systems...";
  String get advice => _advice;

  // Internal Resources
  GenerativeModel? _model;
  CameraController? _cameraController;
  CameraController? get cameraController => _cameraController;

  // Configuration Constants
  // RESEARCH: Use stable 'flash' model to avoid 404s on 'latest'
  static const _modelName = 'gemini-1.5-flash';

  // System Prompt for Spatial Awareness
  // RESEARCH: Injected via constructor in v0.4.x SDK
  final _systemInstruction =
      Content.system('You are a Spatial Safety Assistant for the blind. '
          'Detect holes, drops, obstacles, or hazards in the path. '
          'Estimate distance in steps or meters. '
          'Format output strictly as: : -. '
          'Example: DANGER : Forward - 2 steps. or SAFE : Path Clear.');

  /// Main Initialization Flow
  Future<void> initialize(String apiKey) async {
    _updateStatus(DeepSightStatus.initializing, "Booting DeepSight Core...");

    try {
      // 1. Initialize Generative AI
      // RESEARCH: Explicitly use v1beta to ensure systemInstruction compatibility
      _model = GenerativeModel(
        model: _modelName,
        apiKey: apiKey,
        requestOptions: const RequestOptions(apiVersion: 'v1beta'),
        systemInstruction: _systemInstruction,
        generationConfig: GenerationConfig(
          temperature:
              0.4, // Lower temperature for more deterministic safety warnings
          maxOutputTokens: 128, // Low token count for speed
        ),
      );

      // 3. Initialize Camera (with Failure Containment)
      await _initializeCameraSafely();

      _updateStatus(DeepSightStatus.ready, "System Ready. Scanning...");
    } catch (e) {
      debugPrint("Critical Initialization Failure: $e");
      _updateStatus(DeepSightStatus.error, "System Failure: $e");
    }
  }

  /// Defensive Camera Initialization
  /// Handles timeouts and platform hangs common on Android 14
  Future<void> _initializeCameraSafely() async {
    try {
      _advice = "Connecting to Vision Hardware...";
      notifyListeners();

      // RESEARCH: Timeout prevents infinite hang if Camera HAL is locked
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          debugPrint("Camera enumeration timed out.");
          return [];
        },
      );

      if (cameras.isEmpty) {
        debugPrint("No cameras found or access denied.");
        _updateStatus(DeepSightStatus.cameraFailure, "Camera Unavailable");
        return;
      }

      // Filter for rear camera, avoid virtual/test cameras
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Initialize Controller
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium, // Medium resolution balances speed/quality
        enableAudio:
            false, // RESEARCH: Disabling audio prevents conflict with AudioPlayers on iOS
        imageFormatGroup: !kIsWeb && Platform.isAndroid
            ? ImageFormatGroup.nv21 // Native Android format for efficiency
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
    } catch (e) {
      debugPrint("Camera Hardware Error: $e");
      // Do not crash the app; enter degraded mode
      _updateStatus(DeepSightStatus.cameraFailure, "Vision System Offline");
    }
  }

  /// Core Analysis Loop
  Future<void> analyzeFrame() async {
    if (_status == DeepSightStatus.processing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    _updateStatus(DeepSightStatus.processing,
        _advice); // Keep old advice while processing

    try {
      // Capture Image
      final XFile image = await _cameraController!.takePicture();
      final Uint8List imageBytes = await image.readAsBytes();

      // Construct Payload
      final content = [
        Content.multi([
          TextPart("Analyze this scene for navigation hazards."),
          DataPart('image/jpeg', imageBytes)
        ])
      ];

      // Inference
      final response = await _model!.generateContent(content);
      final text = response.text ?? "No analysis returned.";

      _updateStatus(DeepSightStatus.ready, text);
    } catch (e) {
      debugPrint("Inference Error: $e");
      // Don't show error to user immediately, just hold previous state or warn
      _updateStatus(DeepSightStatus.ready, "Retrying connection...");
    }
  }

  void _updateStatus(DeepSightStatus status, String advice) {
    _status = status;
    _advice = advice;
    notifyListeners();
  }

  void disposeResources() {
    _cameraController?.dispose();
    super.dispose();
  }
}
