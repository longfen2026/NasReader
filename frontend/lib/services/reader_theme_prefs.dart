import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/reader_theme.dart';
import 'app_logger.dart';

/// 阅读背景主题持久化，TXT 与 EPUB 两个阅读器共用同一份
class ReaderThemePrefs {
  static const String _key = 'reader_theme_name';

  /// 主题里的 Color 与 asset 路径都是编译期常量，存下来也无法回填，
  /// 因此只存名称，读回时到 [ReaderThemes.all] 里取回完整定义
  static Future<ReaderThemeData> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_key);
      if (name == null || name.isEmpty) return ReaderThemes.parchment;
      return resolveByName(name);
    } catch (e) {
      AppLogger.log('⚠️ 阅读背景读取失败: $e');
      return ReaderThemes.parchment;
    }
  }

  static Future<void> save(ReaderThemeData theme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, theme.name);
    } catch (e) {
      AppLogger.log('⚠️ 阅读背景保存失败: $e');
    }
  }

  /// 主题被改名或下线后，旧存档要能安全退回默认背景而不是抛异常
  static ReaderThemeData resolveByName(String name) {
    for (final theme in ReaderThemes.all) {
      if (theme.name == name) return theme;
    }
    return ReaderThemes.parchment;
  }

  // ==================== 自定义文字颜色 ====================

  static const String _customKey = 'reader_theme_custom_text_colors';

  /// 各主题的自定义文字颜色，按主题名持久化为 JSON Map（name -> ARGB int）
  static Future<Map<String, int>> loadCustomTextColors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_customKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (e) {
      AppLogger.log('⚠️ 自定义文字颜色读取失败: $e');
      return {};
    }
  }

  /// 为主题绑定一个自定义文字颜色
  static Future<void> saveCustomTextColor(String themeName, Color color) async {
    try {
      final map = await loadCustomTextColors();
      map[themeName] = color.toARGB32();
      await _writeCustomColors(map);
    } catch (e) {
      AppLogger.log('⚠️ 自定义文字颜色保存失败: $e');
    }
  }

  /// 重置主题的自定义文字颜色（还原为默认色）
  static Future<void> clearCustomTextColor(String themeName) async {
    try {
      final map = await loadCustomTextColors();
      if (map.remove(themeName) == null) return;
      await _writeCustomColors(map);
    } catch (e) {
      AppLogger.log('⚠️ 自定义文字颜色重置失败: $e');
    }
  }

  static Future<void> _writeCustomColors(Map<String, int> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customKey, jsonEncode(map));
  }

  /// 主题实际使用的文字颜色：有自定义颜色优先，否则用默认色
  static Color effectiveTextColor(
      ReaderThemeData theme, Map<String, int> customMap) {
    final value = customMap[theme.name];
    if (value != null) return Color(value);
    return theme.textColor;
  }
}
