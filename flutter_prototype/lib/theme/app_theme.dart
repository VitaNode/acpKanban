import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppConstants.primaryColor,
        primary: AppConstants.primaryColor,
        secondary: AppConstants.secondaryColor,
        surface: const Color(0xFFF5F5F5), // Level 2: Column background
        onSurface: AppConstants.textPrimary,
        error: AppConstants.errorColor,
      ),
      scaffoldBackgroundColor: const Color(0xFFFFFFFF), // Level 1: Global background
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFFFF),
        foregroundColor: AppConstants.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFFFFFFF), // Level 3: Card background
        elevation: 1,
        shadowColor: Colors.black.withOpacity(0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.space12),
        ),
        margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppConstants.textPrimary),
        headlineMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppConstants.textPrimary),
        bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppConstants.textPrimary),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.normal, color: AppConstants.textPrimary),
        labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppConstants.textSecondary),
        bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: AppConstants.textSecondary),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade200,
        thickness: 1,
        space: AppConstants.space24,
      ),
    );
  }

  static ThemeData get darkTheme {
    const level1Bg = Color(0xFF000000); // Scaffold
    const level2Bg = Color(0xFF1A1A1A); // Column / Surface
    const level3Bg = Color(0xFF2C2C2C); // Card / Bubble
    const textPrimary = Color(0xFFE1E1E1);
    const textSecondary = Color(0xFFAAAAAA);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppConstants.primaryColor,
        brightness: Brightness.dark,
        primary: AppConstants.primaryColor,
        secondary: AppConstants.secondaryColor,
        surface: level2Bg,
        onSurface: textPrimary,
        error: AppConstants.errorColor,
      ),
      scaffoldBackgroundColor: level1Bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: level1Bg,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: level3Bg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.space12),
        ),
        margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textPrimary),
        headlineMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary),
        bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: textPrimary),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.normal, color: textPrimary),
        labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textSecondary),
        bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: textSecondary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: level2Bg,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppConstants.space8), borderSide: BorderSide.none),
        labelStyle: const TextStyle(color: textSecondary),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withOpacity(0.05),
        thickness: 1,
        space: AppConstants.space24,
      ),
    );
  }
}
