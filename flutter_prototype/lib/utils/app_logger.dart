import 'package:flutter/foundation.dart';

class AppLogger {
  static void info(String message) {
    if (kDebugMode) {
      print('[INFO] $message');
    }
  }

  static void warning(String message, [Object? error]) {
    if (kDebugMode) {
      print('[WARN] $message');
      if (error != null) print(error);
    }
  }

  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      print('[ERROR] $message');
      if (error != null) print(error);
      if (stackTrace != null) print(stackTrace);
    }
  }

  static void debug(String message) {
    if (kDebugMode) {
      print('[DEBUG] $message');
    }
  }
}
