import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static final ThemeService _instance = ThemeService._internal();
  factory ThemeService() => _instance;
  ThemeService._internal();

  static const String _themeKey = 'theme_mode';
  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString(_themeKey);
    if (savedMode == 'dark') {
      _themeMode = ThemeMode.dark;
    } else if (savedMode == 'light') {
      _themeMode = ThemeMode.light;
    } else {
      _themeMode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    if (_themeMode == ThemeMode.dark) {
      _themeMode = ThemeMode.light;
    } else {
      _themeMode = ThemeMode.dark;
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, _themeMode == ThemeMode.dark ? 'dark' : 'light');
    notifyListeners();
  }
}
