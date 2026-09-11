// lib/services/server_profile_service.dart
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 单条服务器登录记录：地址存明文，密码存安全存储
class ServerProfile {
  final String url;
  final String username;

  /// 是否记住密码；为 false 时安全存储中不保留密码
  final bool rememberPassword;

  const ServerProfile({
    required this.url,
    this.username = '',
    this.rememberPassword = true,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'rememberPassword': rememberPassword,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
    url: (json['url'] ?? '').toString(),
    username: (json['username'] ?? '').toString(),
    rememberPassword: json['rememberPassword'] != false,
  );
}

/// 管理最近使用过的服务器地址与对应的登录信息
class ServerProfileService {
  static const String _keyProfiles = 'server_profiles';
  static const String _passwordKeyPrefix = 'server_password_';

  /// 最多保留的历史地址条数
  static const int maxProfiles = 3;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 归一化地址，保证同一服务器不会因末尾斜杠产生重复记录
  static String normalizeUrl(String url) {
    var cleaned = url.trim();
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  /// 按最近使用时间倒序返回历史记录（首条为最近使用）
  static Future<List<ServerProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyProfiles);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(ServerProfile.fromJson)
          .where((p) => p.url.isNotEmpty)
          .toList();
    } catch (e) {
      AppLogger.log('⚠️ 服务器历史记录损坏，已重置: $e');
      await prefs.remove(_keyProfiles);
      return const [];
    }
  }

  /// 保存/更新一条记录并置顶，超出上限时淘汰最久未使用的记录及其密码
  static Future<void> saveProfile({
    required String url,
    required String username,
    required String password,
    required bool rememberPassword,
  }) async {
    final normalized = normalizeUrl(url);
    if (normalized.isEmpty) return;

    final profiles = (await loadProfiles())
        .where((p) => p.url != normalized)
        .toList();

    profiles.insert(
      0,
      ServerProfile(
        url: normalized,
        username: username.trim(),
        rememberPassword: rememberPassword,
      ),
    );

    final dropped = profiles.length > maxProfiles
        ? profiles.sublist(maxProfiles)
        : const <ServerProfile>[];
    final kept = profiles.take(maxProfiles).toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyProfiles,
      jsonEncode(kept.map((p) => p.toJson()).toList()),
    );

    for (final item in dropped) {
      await _deletePassword(item.url);
    }

    if (rememberPassword && password.isNotEmpty) {
      await _writePassword(normalized, password);
    } else {
      await _deletePassword(normalized);
    }
  }

  /// 删除一条历史记录及其密码
  static Future<void> removeProfile(String url) async {
    final normalized = normalizeUrl(url);
    final profiles = (await loadProfiles())
        .where((p) => p.url != normalized)
        .toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
    await _deletePassword(normalized);
  }

  /// 读取指定地址记住的密码，未记住时返回空字符串
  static Future<String> readPassword(String url) async {
    try {
      final value = await _secureStorage.read(
        key: '$_passwordKeyPrefix${normalizeUrl(url)}',
      );
      return value ?? '';
    } catch (e) {
      AppLogger.log('⚠️ 读取已保存密码失败: $e');
      return '';
    }
  }

  /// 修改密码后清理本地缓存的旧密码，避免自动填充错误凭证
  static Future<void> clearPassword(String url) => _deletePassword(url);

  static Future<void> _writePassword(String url, String password) async {
    try {
      await _secureStorage.write(
        key: '$_passwordKeyPrefix$url',
        value: password,
      );
    } catch (e) {
      AppLogger.log('⚠️ 保存密码到安全存储失败: $e');
    }
  }

  static Future<void> _deletePassword(String url) async {
    try {
      await _secureStorage.delete(key: '$_passwordKeyPrefix${normalizeUrl(url)}');
    } catch (e) {
      AppLogger.log('⚠️ 清除已保存密码失败: $e');
    }
  }
}
