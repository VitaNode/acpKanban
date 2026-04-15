import 'package:flutter/material.dart';

class AppConstants {
  // Durations
  static const autoSaveDebounce = Duration(milliseconds: 500);
  static const animationDuration = Duration(milliseconds: 300);
  static const retryDelayBase = Duration(milliseconds: 500);

  // Colors
  static const primaryColor = Color(0xFF008080); // Teal
  static const secondaryColor = Color(0xFF004D40);
  static const backgroundColor = Color(0xFFFFFFFF);
  static const surfaceColor = Color(0xFFF5F5F5);
  static const errorColor = Color(0xFFD32F2F);
  static const successColor = Color(0xFF388E3C);
  
  static const textPrimary = Color(0xFF212121);
  static const textSecondary = Color(0xFF757575);
  static const textHint = Color(0xFFBDBDBD);

  // Spacing (Strict Base-4 Rule)
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space12 = 12.0;
  static const double space16 = 16.0;
  static const double space24 = 24.0;
  static const double space32 = 32.0;
  
  // Text Styles
  static const metadataStyle = TextStyle(
    fontSize: 11,
    fontFamily: 'monospace',
    color: textSecondary,
  );
  
  static const horizontalPadding = 16.0;
}
