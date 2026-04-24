import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

@immutable
class CustomColors extends ThemeExtension<CustomColors> {
  final Color? success;
  final Color? warning;
  final Color? info;

  const CustomColors({
    required this.success,
    required this.warning,
    required this.info,
  });

  @override
  CustomColors copyWith({Color? success, Color? warning, Color? info}) {
    return CustomColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
    );
  }

  @override
  CustomColors lerp(ThemeExtension<CustomColors>? other, double t) {
    if (other is! CustomColors) return this;
    return CustomColors(
      success: Color.lerp(success, other.success, t),
      warning: Color.lerp(warning, other.warning, t),
      info: Color.lerp(info, other.info, t),
    );
  }
}

class AppTheme {
  // Brand color副本 (针对深色模式进行降饱和处理)
  static const Color _primaryDark = Color(0xFF4DB6AC); // Desaturated Teal
  static const Color _surfaceDark = Color(0xFF121212); // Material Deep Grey
  
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppConstants.primaryColor,
      primary: AppConstants.primaryColor,
      brightness: Brightness.light,
      surface: const Color(0xFFFCFCFC),
      surfaceContainer: const Color(0xFFF3F3F3),
    );

    return _buildTheme(colorScheme, const CustomColors(
      success: Color(0xFF2E7D32),
      warning: Color(0xFFED6C02),
      info: Color(0xFF0288D1),
    ));
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppConstants.primaryColor,
      primary: _primaryDark, // 使用降饱和的品牌色
      onPrimary: const Color(0xFF002020),
      brightness: Brightness.dark,
      surface: _surfaceDark, // 避免纯黑
      surfaceContainer: const Color(0xFF1E1E1E), // 更亮的容器 (Elevation 1)
      surfaceContainerHigh: const Color(0xFF2C2C2C), // 弹窗/高层级 (Elevation 3)
      onSurface: const Color(0xFFE1E3E1), // 避免纯白，使用灰白色
    );

    return _buildTheme(colorScheme, const CustomColors(
      success: Color(0xFFA5D6A7), // 降饱和绿色
      warning: Color(0xFFFFCC80), // 降饱和橙色
      info: Color(0xFF90CAF9),    // 降饱和蓝色
    ));
  }

  static ThemeData _buildTheme(ColorScheme colorScheme, CustomColors customColors) {
    final bool isDark = colorScheme.brightness == Brightness.dark;
    final Color onSurfaceBase = colorScheme.onSurface;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      extensions: [customColors],
      scaffoldBackgroundColor: colorScheme.surface,
      
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: onSurfaceBase,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: onSurfaceBase.withOpacity(AppConstants.highEmphasis),
        ),
      ),

      cardTheme: CardThemeData(
        color: isDark ? colorScheme.surfaceContainerHigh : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
          side: BorderSide(
            color: isDark 
                ? Colors.white.withOpacity(0.05) // 更细微的边缘
                : colorScheme.outlineVariant.withOpacity(0.1),
            width: 1,
          ),
        ),
        margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      ),

      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontSize: 24, 
          fontWeight: FontWeight.bold, 
          color: onSurfaceBase.withOpacity(AppConstants.highEmphasis)
        ),
        headlineMedium: TextStyle(
          fontSize: 18, 
          fontWeight: FontWeight.bold, 
          color: onSurfaceBase.withOpacity(AppConstants.highEmphasis)
        ),
        bodyLarge: TextStyle(
          fontSize: 16, 
          fontWeight: FontWeight.w500, 
          color: onSurfaceBase.withOpacity(AppConstants.highEmphasis)
        ),
        bodyMedium: TextStyle(
          fontSize: 14, 
          fontWeight: FontWeight.normal, 
          color: onSurfaceBase.withOpacity(AppConstants.highEmphasis)
        ),
        bodySmall: TextStyle(
          fontSize: 12, 
          fontWeight: FontWeight.normal, 
          color: onSurfaceBase.withOpacity(AppConstants.mediumEmphasis)
        ),
        labelLarge: TextStyle(
          fontSize: 12, 
          fontWeight: FontWeight.w600, 
          color: colorScheme.primary
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
          borderSide: BorderSide(
            color: isDark ? Colors.white.withOpacity(0.05) : Colors.transparent
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        labelStyle: TextStyle(color: onSurfaceBase.withOpacity(AppConstants.mediumEmphasis)),
        hintStyle: TextStyle(color: onSurfaceBase.withOpacity(AppConstants.disabledOpacity)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppConstants.space16, 
          vertical: AppConstants.space12
        ),
      ),

      dividerTheme: DividerThemeData(
        color: onSurfaceBase.withOpacity(isDark ? 0.08 : 0.12),
        thickness: 1,
        space: AppConstants.space24,
      ),

      iconTheme: IconThemeData(
        color: onSurfaceBase.withOpacity(AppConstants.mediumEmphasis),
        size: 20,
      ),

      // 交互状态叠加层处理
      hoverColor: colorScheme.primary.withOpacity(0.08),
      splashColor: colorScheme.primary.withOpacity(0.12),
    );
  }
}
