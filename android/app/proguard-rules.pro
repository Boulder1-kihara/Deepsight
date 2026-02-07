# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# CameraX
-keep class androidx.camera.** { *; }

# Generative AI (if applicable via JNI, though mostly pure Dart)
# Keep generic plugin classes
-keep class com.google.** { *; }
