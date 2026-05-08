import 'package:flutter/material.dart';

class AppConstants {
  // Durations
  static const autoSaveDebounce = Duration(milliseconds: 500);
  static const animationDuration = Duration(milliseconds: 300);
  static const retryDelayBase = Duration(milliseconds: 500);
  static const streamThrottleMs = Duration(milliseconds: 60);

  // Spacing (Strict 8px Base System)
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space12 = 12.0;
  static const double space16 = 16.0;
  static const double space24 = 24.0;
  static const double space32 = 32.0;
  static const double space40 = 40.0;
  static const double space48 = 48.0;

  // Radius Tokens
  static const double radiusSmall = 8.0;   // Buttons, small containers
  static const double radiusMedium = 12.0; // Cards, dialogs
  static const double radiusLarge = 24.0;  // Input fields, chips
  static const double radiusFull = 99.0;   // Pill buttons

  // Emphasis (Opacity)
  static const double highEmphasis = 0.87;
  static const double mediumEmphasis = 0.60;
  static const double disabledOpacity = 0.38;

  // Layout
  static const double maxContentWidth = 800.0;
  static const double horizontalPadding = 16.0;

  // Branding (Seed Colors)
  static const primaryColor = Color(0xFF008080); // Teal
}
