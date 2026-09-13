// lib/config/theme_manager.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';

/// App 主题色预设（Purple / Blue / Green / Amber / Teal），浅色配色方案的颜色值来自设计规范
enum AppThemePreset {
  purple('Purple'),
  blue('Blue'),
  green('Green'),
  amber('Amber'),
  teal('Teal');

  final String label;
  const AppThemePreset(this.label);

  /// Material 3 浅色配色方案
  ColorScheme get lightColorScheme => switch (this) {
        AppThemePreset.purple => const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF6750A4),
            onPrimary: Color(0xFFFFFFFF),
            primaryContainer: Color(0xFFEADDFF),
            onPrimaryContainer: Color(0xFF21005D),
            secondary: Color(0xFF635A75),
            onSecondary: Color(0xFFFFFFFF),
            secondaryContainer: Color(0xFFE8DEF8),
            onSecondaryContainer: Color(0xFF1D192B),
            tertiary: Color(0xFF7D5260),
            onTertiary: Color(0xFFFFFFFF),
            tertiaryContainer: Color(0xFFFFD8E4),
            onTertiaryContainer: Color(0xFF31111D),
            error: Color(0xFFB3261E),
            onError: Color(0xFFFFFFFF),
            errorContainer: Color(0xFFF9DEDC),
            onErrorContainer: Color(0xFF410E0B),
            surface: Color(0xFFFEF7FF),
            onSurface: Color(0xFF1D1B20),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceContainerLow: Color(0xFFF7F2FA),
            surfaceContainer: Color(0xFFF3EDF7),
            surfaceContainerHigh: Color(0xFFECE6F0),
            surfaceContainerHighest: Color(0xFFE6E0E9),
            onSurfaceVariant: Color(0xFF49454F),
            outline: Color(0xFF79747E),
            outlineVariant: Color(0xFFCAC4D0),
            inverseSurface: Color(0xFF322F35),
            onInverseSurface: Color(0xFFF5EFF7),
            inversePrimary: Color(0xFFD0BCFF),
          ),
        AppThemePreset.blue => const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF0B57D0),
            onPrimary: Color(0xFFFFFFFF),
            primaryContainer: Color(0xFFD3E3FD),
            onPrimaryContainer: Color(0xFF041E49),
            secondary: Color(0xFF5A5C7C),
            onSecondary: Color(0xFFFFFFFF),
            secondaryContainer: Color(0xFFDCE2F9),
            onSecondaryContainer: Color(0xFF131C2B),
            tertiary: Color(0xFF7A5774),
            onTertiary: Color(0xFFFFFFFF),
            tertiaryContainer: Color(0xFFFFD8EE),
            onTertiaryContainer: Color(0xFF2E1125),
            error: Color(0xFFB3261E),
            onError: Color(0xFFFFFFFF),
            errorContainer: Color(0xFFF9DEDC),
            onErrorContainer: Color(0xFF410E0B),
            surface: Color(0xFFFAF9FD),
            onSurface: Color(0xFF1B1B1F),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceContainerLow: Color(0xFFF3F3FA),
            surfaceContainer: Color(0xFFEEEDF3),
            surfaceContainerHigh: Color(0xFFE9E8EF),
            surfaceContainerHighest: Color(0xFFE3E2E6),
            onSurfaceVariant: Color(0xFF44474E),
            outline: Color(0xFF74777F),
            outlineVariant: Color(0xFFC4C6D0),
            inverseSurface: Color(0xFF303034),
            onInverseSurface: Color(0xFFF2F0F4),
            inversePrimary: Color(0xFFA8C7FA),
          ),
        AppThemePreset.green => const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF2E6A45),
            onPrimary: Color(0xFFFFFFFF),
            primaryContainer: Color(0xFFB0F1C2),
            onPrimaryContainer: Color(0xFF00210F),
            secondary: Color(0xFF516356),
            onSecondary: Color(0xFFFFFFFF),
            secondaryContainer: Color(0xFFD3E8D8),
            onSecondaryContainer: Color(0xFF102016),
            tertiary: Color(0xFF3E6374),
            onTertiary: Color(0xFFFFFFFF),
            tertiaryContainer: Color(0xFFC2E8FF),
            onTertiaryContainer: Color(0xFF001E2C),
            error: Color(0xFFB3261E),
            onError: Color(0xFFFFFFFF),
            errorContainer: Color(0xFFF9DEDC),
            onErrorContainer: Color(0xFF410E0B),
            surface: Color(0xFFF6FBF4),
            onSurface: Color(0xFF181D18),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceContainerLow: Color(0xFFF0F5EE),
            surfaceContainer: Color(0xFFEAF0E8),
            surfaceContainerHigh: Color(0xFFE4EAE2),
            surfaceContainerHighest: Color(0xFFDEE4DC),
            onSurfaceVariant: Color(0xFF414941),
            outline: Color(0xFF707972),
            outlineVariant: Color(0xFFBFC9C0),
            inverseSurface: Color(0xFF2D322D),
            onInverseSurface: Color(0xFFEEF2EB),
            inversePrimary: Color(0xFF95D5A7),
          ),
        AppThemePreset.amber => const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF8B5000),
            onPrimary: Color(0xFFFFFFFF),
            primaryContainer: Color(0xFFFFDCC2),
            onPrimaryContainer: Color(0xFF2C1600),
            secondary: Color(0xFF725A44),
            onSecondary: Color(0xFFFFFFFF),
            secondaryContainer: Color(0xFFF6DFC8),
            onSecondaryContainer: Color(0xFF271905),
            tertiary: Color(0xFF4C6836),
            onTertiary: Color(0xFFFFFFFF),
            tertiaryContainer: Color(0xFFD5EDC0),
            onTertiaryContainer: Color(0xFF0E2004),
            error: Color(0xFFB3261E),
            onError: Color(0xFFFFFFFF),
            errorContainer: Color(0xFFF9DEDC),
            onErrorContainer: Color(0xFF410E0B),
            surface: Color(0xFFFFF8F5),
            onSurface: Color(0xFF211A14),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceContainerLow: Color(0xFFFCF1EA),
            surfaceContainer: Color(0xFFF7ECE4),
            surfaceContainerHigh: Color(0xFFF3E6DE),
            surfaceContainerHighest: Color(0xFFEDE0D8),
            onSurfaceVariant: Color(0xFF51443B),
            outline: Color(0xFF83746A),
            outlineVariant: Color(0xFFD6C3B6),
            inverseSurface: Color(0xFF362F28),
            onInverseSurface: Color(0xFFFBEEE5),
            inversePrimary: Color(0xFFFFB77C),
          ),
        AppThemePreset.teal => const ColorScheme(
            brightness: Brightness.light,
            primary: Color(0xFF00696E),
            onPrimary: Color(0xFFFFFFFF),
            primaryContainer: Color(0xFF9CF1F6),
            onPrimaryContainer: Color(0xFF002022),
            secondary: Color(0xFF4D6263),
            onSecondary: Color(0xFFFFFFFF),
            secondaryContainer: Color(0xFFCCE8E9),
            onSecondaryContainer: Color(0xFF051F20),
            tertiary: Color(0xFF445E8C),
            onTertiary: Color(0xFFFFFFFF),
            tertiaryContainer: Color(0xFFD2E4FF),
            onTertiaryContainer: Color(0xFF001C3B),
            error: Color(0xFFB3261E),
            onError: Color(0xFFFFFFFF),
            errorContainer: Color(0xFFF9DEDC),
            onErrorContainer: Color(0xFF410E0B),
            surface: Color(0xFFF4FBFB),
            onSurface: Color(0xFF161D1D),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceContainerLow: Color(0xFFEEF5F5),
            surfaceContainer: Color(0xFFE8EFEF),
            surfaceContainerHigh: Color(0xFFE2EAEA),
            surfaceContainerHighest: Color(0xFFDDE4E4),
            onSurfaceVariant: Color(0xFF3F4948),
            outline: Color(0xFF6F7979),
            outlineVariant: Color(0xFFBEC8C8),
            inverseSurface: Color(0xFF2B3232),
            onInverseSurface: Color(0xFFECF2F2),
            inversePrimary: Color(0xFF80D5DA),
          ),
      };

  /// 深色配色方案：以预设主色为种子生成，保证深色模式下的对比度与色调统一
  ColorScheme get darkColorScheme => ColorScheme.fromSeed(
        seedColor: lightColorScheme.primary,
        brightness: Brightness.dark,
      );
}

class ThemeManager {
  static final ValueNotifier<ThemeMode> themeModeNotifier =
      ValueNotifier(ThemeMode.system);

  /// App 主题色预设，默认 Purple
  static final ValueNotifier<AppThemePreset> presetNotifier =
      ValueNotifier(AppThemePreset.purple);

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTheme = prefs.getString('app_theme_mode');
      if (savedTheme != null) {
        themeModeNotifier.value = ThemeMode.values.firstWhere(
          (e) => e.name == savedTheme,
          orElse: () => ThemeMode.system,
        );
      }
      final savedPreset = prefs.getString('app_theme_preset');
      if (savedPreset != null) {
        presetNotifier.value = AppThemePreset.values.firstWhere(
          (e) => e.name == savedPreset,
          orElse: () => AppThemePreset.purple,
        );
      }
    } catch (e) {
      AppLogger.log('⚠️ 主题偏好读取失败，回退系统主题: $e');
    }
  }

  static Future<void> updateTheme(ThemeMode mode) async {
    themeModeNotifier.value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_theme_mode', mode.name);
    } catch (e) {
      AppLogger.log('⚠️ 主题偏好保存失败，重启后将丢失: $e');
    }
  }

  /// 切换 App 主题色预设并持久化
  static Future<void> updatePreset(AppThemePreset preset) async {
    presetNotifier.value = preset;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_theme_preset', preset.name);
    } catch (e) {
      AppLogger.log('⚠️ 主题色偏好保存失败，重启后将丢失: $e');
    }
  }
}
