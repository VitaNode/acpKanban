import 'package:flutter/material.dart';

class AppConstants {
  // Durations
  static const autoSaveDebounce = Duration(milliseconds: 500);
  static const animationDuration = Duration(milliseconds: 300);
  static const retryDelayBase = Duration(milliseconds: 500);

  // Colors
  static final metadataColor = Colors.grey[500];
  static final metadataIconColor = Colors.grey[300];
  static const primaryColor = Colors.indigo;
  static const errorColor = Colors.red;
  static const successColor = Colors.green;
  
  // Text Styles
  static const metadataStyle = TextStyle(
    fontSize: 11,
    fontFamily: 'monospace',
  );
  
  // Layout
  static const horizontalPadding = 20.0;
}
