import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../core/network_client.dart';
import '../models/favorite_book.dart';
import 'app_logger.dart';

/// 收藏夹存储服务。
/// 本地 SharedPreferences 先写入保证离线可用，登录状态下再与后端做双向 LWW 合并同步。
class FavoriteService {
  static const String _storageKey = 'local_favorite_books_map';
  static const String _syncPath = '/api/v1/sync/favorites';

  /// 取消收藏的本地墓碍保留时长，需与后端 favoriteTombstoneTTL 保持一致
  static const Duration _tombstoneTtl = Duration(days: 30);

  /// 收藏集合变更通知，供书架 / 书库 / 收藏夹页面联动刷新
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Map<String, FavoriteBook>? _cache;

  static Future<Map<String, FavoriteBook>> _load() async {
    if (_cache != null) return _cache!;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    final Map<String, FavoriteBook> result = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          final item = FavoriteBook.fromJson(Map<String, dynamic>.from(value));
          if (item.bookId.isNotEmpty) result[item.bookId] = item;
        });
      } catch (e) {
        AppLogger.log('⚠️ 收藏夹数据解析失败，按空集合处理: $e');
      }
    }
    _cache = result;
    return result;
  }

  static Future<void> _persist(Map<String, FavoriteBook> map) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = map.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_storageKey, jsonEncode(encoded));
    revision.value++;
  }

  /// 按收藏时间倒序返回全部有效收藏（排除墓碍）
  static Future<List<FavoriteBook>> getAll() async {
    final map = await _load();
    return map.values.where((e) => !e.isDeleted).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  /// 已收藏的 bookId 集合，供列表渲染星标状态
  static Future<Set<String>> getFavoriteIds() async {
    final map = await _load();
    return map.values.where((e) => !e.isDeleted).map((e) => e.bookId).toSet();
  }

  static Future<bool> isFavorite(String bookId) async {
    final map = await _load();
    final item = map[bookId];
    return item != null && !item.isDeleted;
  }

  static Future<void> add({
    required String bookId,
    required String title,
    required String fileName,
    String remotePath = '',
  }) async {
    if (bookId.isEmpty) return;
    final map = await _load();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = map[bookId];
    map[bookId] = FavoriteBook(
      bookId: bookId,
      title: title,
      fileName: fileName,
      remotePath: remotePath,
      // 复用原有收藏时间，避免重复收藏后在列表里跳位
      addedAt: existing != null && !existing.isDeleted ? existing.addedAt : now,
      updatedAt: now,
    );
    await _persist(map);
    _pushInBackground();
  }

  /// 取消收藏：写墓碍而非物理删除，保证删除动作能同步到其它设备
  static Future<void> remove(String bookId) async {
    final map = await _load();
    final existing = map[bookId];
    if (existing == null || existing.isDeleted) return;

    map[bookId] = existing.copyWith(
      isDeleted: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _persist(map);
    _pushInBackground();
  }

  /// 切换收藏状态，返回切换后是否已收藏
  static Future<bool> toggle({
    required String bookId,
    required String title,
    required String fileName,
    String remotePath = '',
  }) async {
    if (await isFavorite(bookId)) {
      await remove(bookId);
      return false;
    }
    await add(
      bookId: bookId,
      title: title,
      fileName: fileName,
      remotePath: remotePath,
    );
    return true;
  }

  /// 与后端双向合并收藏夹，返回合并后的有效收藏列表。
  /// 未登录或网络异常时静默回退本地数据，保证离线可用。
  static Future<List<FavoriteBook>> syncWithServer() async {
    final localMap = await _load();
    if (!ApiConfig.isLoggedIn) return getAll();

    final expireBefore = DateTime.now()
        .subtract(_tombstoneTtl)
        .millisecondsSinceEpoch;

    try {
      final dio = NetworkClient.getDio();
      final response = await dio.post(
        _syncPath,
        data: {'favorites': localMap.values.map((e) => e.toJson()).toList()},
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      final body = response.data;
      if (response.statusCode == 200 && body is Map && body['data'] is List) {
        final merged = <String, FavoriteBook>{...localMap};
        var changed = false;

        for (final raw in body['data'] as List) {
          if (raw is! Map) continue;
          final remote = FavoriteBook.fromJson(Map<String, dynamic>.from(raw));
          if (remote.bookId.isEmpty) continue;

          final local = merged[remote.bookId];
          if (local == null || remote.updatedAt > local.updatedAt) {
            merged[remote.bookId] = remote;
            changed = true;
          }
        }

        // 清理超过保留期的墓碍，避免本地无限累积
        final before = merged.length;
        merged.removeWhere((_, v) => v.isDeleted && v.updatedAt < expireBefore);
        if (merged.length != before) changed = true;

        _cache = merged;
        // 无差异时不落盘，避免 revision 白白触发页面刷新
        if (changed) await _persist(merged);
      } else {
        AppLogger.log('⚠️ 收藏夹同步响应异常 [${response.statusCode}]: $body');
      }
    } catch (e) {
      AppLogger.log('🌐 离线模式或网络错误，回退本地收藏夹: $e');
    }

    return getAll();
  }

  /// 本地写入后不阻塞 UI 地推送到后端，失败只记日志，等下次同步补齐
  static void _pushInBackground() {
    if (!ApiConfig.isLoggedIn) return;
    unawaited(
      syncWithServer().then<void>(
        (_) {},
        onError: (Object e) => AppLogger.log('⚠️ 收藏夹后端同步推迟: $e'),
      ),
    );
  }

  /// 登出时清空本地收藏，避免不同账号的数据互相污染
  static Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    _cache = {};
    revision.value++;
  }

  /// 书籍更新（内容指纹变化）后的收藏迁移：把旧 bookId 名下的收藏迁到新 bookId，
  /// 并同步更新冗余的文件名与远端路径，最后后台推送到云端。
  static Future<void> migrateBookId(
    String oldBookId,
    String newBookId, {
    String? newTitle,
    String? newFileName,
    String? newRemotePath,
  }) async {
    if (oldBookId == newBookId || oldBookId.isEmpty || newBookId.isEmpty) {
      return;
    }
    final map = await _load();
    final existing = map.remove(oldBookId);
    if (existing == null) return;

    if (map.containsKey(newBookId)) {
      // 新键已有收藏记录：以新键为准，丢弃旧键避免互相覆盖
      AppLogger.log('🔀 收藏已存在于新书籍标识，丢弃旧键: $oldBookId');
    } else {
      map[newBookId] = FavoriteBook(
        bookId: newBookId,
        title: newTitle ?? existing.title,
        fileName: newFileName ?? existing.fileName,
        remotePath: newRemotePath ?? existing.remotePath,
        addedAt: existing.addedAt,
        // 时间戳上调，保证推送到云端时按 LWW 覆盖旧记录
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        isDeleted: existing.isDeleted,
      );
      AppLogger.log('🔀 已迁移收藏: $oldBookId -> $newBookId');
    }
    await _persist(map);
    _pushInBackground();
  }

  @visibleForTesting
  static void resetCacheForTest() => _cache = null;
}
