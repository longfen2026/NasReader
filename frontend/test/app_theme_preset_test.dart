import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/config/theme_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppThemePreset', () {
    test('预设包含 Purple / Blue / Green / Amber / Teal，名称唯一且带展示标签', () {
      expect(AppThemePreset.values.map((p) => p.name),
          ['purple', 'blue', 'green', 'amber', 'teal']);
      expect(AppThemePreset.purple.label, 'Purple');
      expect(AppThemePreset.blue.label, 'Blue');
      expect(AppThemePreset.green.label, 'Green');
      expect(AppThemePreset.amber.label, 'Amber');
      expect(AppThemePreset.teal.label, 'Teal');
    });

    test('Purple 浅色配色方案使用设计规范颜色', () {
      final scheme = AppThemePreset.purple.lightColorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF6750A4));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFEADDFF));
      expect(scheme.onPrimaryContainer, const Color(0xFF21005D));
      expect(scheme.secondary, const Color(0xFF635A75));
      expect(scheme.secondaryContainer, const Color(0xFFE8DEF8));
      expect(scheme.onSecondaryContainer, const Color(0xFF1D192B));
      expect(scheme.tertiaryContainer, const Color(0xFFFFD8E4));
      expect(scheme.onTertiaryContainer, const Color(0xFF31111D));
      expect(scheme.surface, const Color(0xFFFEF7FF));
      expect(scheme.surfaceContainerLow, const Color(0xFFF7F2FA));
      expect(scheme.surfaceContainer, const Color(0xFFF3EDF7));
      expect(scheme.surfaceContainerHigh, const Color(0xFFECE6F0));
      expect(scheme.surfaceContainerHighest, const Color(0xFFE6E0E9));
      expect(scheme.onSurface, const Color(0xFF1D1B20));
      expect(scheme.onSurfaceVariant, const Color(0xFF49454F));
      expect(scheme.outline, const Color(0xFF79747E));
      expect(scheme.outlineVariant, const Color(0xFFCAC4D0));
      expect(scheme.inverseSurface, const Color(0xFF322F35));
      expect(scheme.onInverseSurface, const Color(0xFFF5EFF7));
      expect(scheme.inversePrimary, const Color(0xFFD0BCFF));
      expect(scheme.error, const Color(0xFFB3261E));
      expect(scheme.onError, const Color(0xFFFFFFFF));
      expect(scheme.errorContainer, const Color(0xFFF9DEDC));
      expect(scheme.onErrorContainer, const Color(0xFF410E0B));
    });

    test('Blue 浅色配色方案使用设计规范颜色', () {
      final scheme = AppThemePreset.blue.lightColorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF0B57D0));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFD3E3FD));
      expect(scheme.onPrimaryContainer, const Color(0xFF041E49));
      expect(scheme.secondary, const Color(0xFF5A5C7C));
      expect(scheme.secondaryContainer, const Color(0xFFDCE2F9));
      expect(scheme.onSecondaryContainer, const Color(0xFF131C2B));
      expect(scheme.tertiaryContainer, const Color(0xFFFFD8EE));
      expect(scheme.onTertiaryContainer, const Color(0xFF2E1125));
      expect(scheme.surface, const Color(0xFFFAF9FD));
      expect(scheme.surfaceContainerLow, const Color(0xFFF3F3FA));
      expect(scheme.surfaceContainer, const Color(0xFFEEEDF3));
      expect(scheme.surfaceContainerHigh, const Color(0xFFE9E8EF));
      expect(scheme.surfaceContainerHighest, const Color(0xFFE3E2E6));
      expect(scheme.onSurface, const Color(0xFF1B1B1F));
      expect(scheme.onSurfaceVariant, const Color(0xFF44474E));
      expect(scheme.outline, const Color(0xFF74777F));
      expect(scheme.outlineVariant, const Color(0xFFC4C6D0));
      expect(scheme.inverseSurface, const Color(0xFF303034));
      expect(scheme.onInverseSurface, const Color(0xFFF2F0F4));
      expect(scheme.inversePrimary, const Color(0xFFA8C7FA));
      expect(scheme.error, const Color(0xFFB3261E));
      expect(scheme.onError, const Color(0xFFFFFFFF));
      expect(scheme.errorContainer, const Color(0xFFF9DEDC));
      expect(scheme.onErrorContainer, const Color(0xFF410E0B));
    });

    test('Green 浅色配色方案使用设计规范颜色', () {
      final scheme = AppThemePreset.green.lightColorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF2E6A45));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFB0F1C2));
      expect(scheme.onPrimaryContainer, const Color(0xFF00210F));
      expect(scheme.secondary, const Color(0xFF516356));
      expect(scheme.secondaryContainer, const Color(0xFFD3E8D8));
      expect(scheme.onSecondaryContainer, const Color(0xFF102016));
      expect(scheme.tertiaryContainer, const Color(0xFFC2E8FF));
      expect(scheme.onTertiaryContainer, const Color(0xFF001E2C));
      expect(scheme.surface, const Color(0xFFF6FBF4));
      expect(scheme.surfaceContainerLow, const Color(0xFFF0F5EE));
      expect(scheme.surfaceContainer, const Color(0xFFEAF0E8));
      expect(scheme.surfaceContainerHigh, const Color(0xFFE4EAE2));
      expect(scheme.surfaceContainerHighest, const Color(0xFFDEE4DC));
      expect(scheme.onSurface, const Color(0xFF181D18));
      expect(scheme.onSurfaceVariant, const Color(0xFF414941));
      expect(scheme.outline, const Color(0xFF707972));
      expect(scheme.outlineVariant, const Color(0xFFBFC9C0));
      expect(scheme.inverseSurface, const Color(0xFF2D322D));
      expect(scheme.onInverseSurface, const Color(0xFFEEF2EB));
      expect(scheme.inversePrimary, const Color(0xFF95D5A7));
      expect(scheme.error, const Color(0xFFB3261E));
      expect(scheme.onError, const Color(0xFFFFFFFF));
      expect(scheme.errorContainer, const Color(0xFFF9DEDC));
      expect(scheme.onErrorContainer, const Color(0xFF410E0B));
    });

    test('Amber 浅色配色方案使用设计规范颜色', () {
      final scheme = AppThemePreset.amber.lightColorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF8B5000));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFFFDCC2));
      expect(scheme.onPrimaryContainer, const Color(0xFF2C1600));
      expect(scheme.secondary, const Color(0xFF725A44));
      expect(scheme.secondaryContainer, const Color(0xFFF6DFC8));
      expect(scheme.onSecondaryContainer, const Color(0xFF271905));
      expect(scheme.tertiaryContainer, const Color(0xFFD5EDC0));
      expect(scheme.onTertiaryContainer, const Color(0xFF0E2004));
      expect(scheme.surface, const Color(0xFFFFF8F5));
      expect(scheme.surfaceContainerLow, const Color(0xFFFCF1EA));
      expect(scheme.surfaceContainer, const Color(0xFFF7ECE4));
      expect(scheme.surfaceContainerHigh, const Color(0xFFF3E6DE));
      expect(scheme.surfaceContainerHighest, const Color(0xFFEDE0D8));
      expect(scheme.onSurface, const Color(0xFF211A14));
      expect(scheme.onSurfaceVariant, const Color(0xFF51443B));
      expect(scheme.outline, const Color(0xFF83746A));
      expect(scheme.outlineVariant, const Color(0xFFD6C3B6));
      expect(scheme.inverseSurface, const Color(0xFF362F28));
      expect(scheme.onInverseSurface, const Color(0xFFFBEEE5));
      expect(scheme.inversePrimary, const Color(0xFFFFB77C));
      expect(scheme.error, const Color(0xFFB3261E));
      expect(scheme.onError, const Color(0xFFFFFFFF));
      expect(scheme.errorContainer, const Color(0xFFF9DEDC));
      expect(scheme.onErrorContainer, const Color(0xFF410E0B));
    });

    test('Teal 浅色配色方案使用设计规范颜色', () {
      final scheme = AppThemePreset.teal.lightColorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF00696E));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFF9CF1F6));
      expect(scheme.onPrimaryContainer, const Color(0xFF002022));
      expect(scheme.secondary, const Color(0xFF4D6263));
      expect(scheme.secondaryContainer, const Color(0xFFCCE8E9));
      expect(scheme.onSecondaryContainer, const Color(0xFF051F20));
      expect(scheme.tertiaryContainer, const Color(0xFFD2E4FF));
      expect(scheme.onTertiaryContainer, const Color(0xFF001C3B));
      expect(scheme.surface, const Color(0xFFF4FBFB));
      expect(scheme.surfaceContainerLow, const Color(0xFFEEF5F5));
      expect(scheme.surfaceContainer, const Color(0xFFE8EFEF));
      expect(scheme.surfaceContainerHigh, const Color(0xFFE2EAEA));
      expect(scheme.surfaceContainerHighest, const Color(0xFFDDE4E4));
      expect(scheme.onSurface, const Color(0xFF161D1D));
      expect(scheme.onSurfaceVariant, const Color(0xFF3F4948));
      expect(scheme.outline, const Color(0xFF6F7979));
      expect(scheme.outlineVariant, const Color(0xFFBEC8C8));
      expect(scheme.inverseSurface, const Color(0xFF2B3232));
      expect(scheme.onInverseSurface, const Color(0xFFECF2F2));
      expect(scheme.inversePrimary, const Color(0xFF80D5DA));
      expect(scheme.error, const Color(0xFFB3261E));
      expect(scheme.onError, const Color(0xFFFFFFFF));
      expect(scheme.errorContainer, const Color(0xFFF9DEDC));
      expect(scheme.onErrorContainer, const Color(0xFF410E0B));
    });

    test('各预设的主色互不相同', () {
      final primaries =
          AppThemePreset.values.map((p) => p.lightColorScheme.primary).toSet();
      expect(primaries.length, AppThemePreset.values.length);
    });

    test('深色配色方案为深色亮度', () {
      for (final preset in AppThemePreset.values) {
        expect(preset.darkColorScheme.brightness, Brightness.dark);
      }
    });
  });

  group('ThemeManager 主题色预设', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ThemeManager.presetNotifier.value = AppThemePreset.purple;
    });

    test('无历史记录时保持默认 Purple', () async {
      expect(ThemeManager.presetNotifier.value, AppThemePreset.purple);
      await ThemeManager.init();
      expect(ThemeManager.presetNotifier.value, AppThemePreset.purple);
    });

    test('updatePreset 持久化后重新 init 能恢复', () async {
      await ThemeManager.updatePreset(AppThemePreset.blue);
      expect(ThemeManager.presetNotifier.value, AppThemePreset.blue);

      // 模拟重启：通知器回到默认值后重新读取偏好
      ThemeManager.presetNotifier.value = AppThemePreset.purple;
      await ThemeManager.init();
      expect(ThemeManager.presetNotifier.value, AppThemePreset.blue);
    });

    test('已下线预设的旧存档退回 Purple', () async {
      SharedPreferences.setMockInitialValues({'app_theme_preset': 'red'});
      await ThemeManager.init();
      expect(ThemeManager.presetNotifier.value, AppThemePreset.purple);
    });

    test('空字符串存档退回 Purple', () async {
      SharedPreferences.setMockInitialValues({'app_theme_preset': ''});
      await ThemeManager.init();
      expect(ThemeManager.presetNotifier.value, AppThemePreset.purple);
    });
  });
}
