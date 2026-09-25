import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../core/network_client.dart';
import 'app_logger.dart';

class BookProgress {
  final String bookId;
  final String title;
  final String filePath;
  final double progress;
  final String locator;
  final int clientUpdatedAt;

  BookProgress({
    required this.bookId,
    required this.title,
    required this.filePath,
    required this.progress,
    required this.locator,
    required this.clientUpdatedAt,
  });

  /// bookId 是文件指纹，本地缓存文件名需从远端路径推导
  String get fileName {
    final base = p.basename(filePath);
    return base.isNotEmpty && base != '/' ? base : bookId;
  }

  int? get txtByteOffset {
    if (locator.isEmpty) return 0;
    return int.tryParse(locator);
  }

  String? get epubCfi {
    return locator.isNotEmpty ? locator : null;
  }

  /// PDF 以页码（0 起）作为 locator
  int get pdfPage {
    if (locator.isEmpty) return 0;
    final page = int.tryParse(locator) ?? 0;
    return page < 0 ? 0 : page;
  }

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'title': title,
    'file_path': filePath,
    'progress': progress,
    'locator': locator,
    'client_updated_at': clientUpdatedAt,
  };

  factory BookProgress.fromJson(Map<String, dynamic> json) {
    final bookId = (json['book_id'] ?? json['BookID'] ?? '').toString();
    final title = (json['title'] ?? json['Title'] ?? '').toString();
    final filePath = (json['file_path'] ?? json['FilePath'] ?? '').toString();

    final rawProgress = json['progress'] ?? json['Progress'] ?? 0.0;
    final progress = (rawProgress is num)
        ? rawProgress.toDouble()
        : (double.tryParse(rawProgress.toString()) ?? 0.0);

    final locator = (json['locator'] ?? json['Locator'] ?? '').toString();

    final rawTime = json['client_updated_at'] ?? json['ClientUpdatedAt'] ?? 0;
    int clientUpdatedAt = 0;
    if (rawTime is num) {
      clientUpdatedAt = rawTime.toInt();
      if (clientUpdatedAt < 10000000000) clientUpdatedAt *= 1000;
    }

    return BookProgress(
      bookId: bookId,
      title: title,
      filePath: filePath,
      progress: progress,
      locator: locator,
      clientUpdatedAt: clientUpdatedAt,
    );
  }
}

class ProgressSyncService {
  static const String _storageKey = 'local_reading_progress_map';

  /// 已从书架移除但云端记录仍保留的书籍，避免远端同步把它们拉回书架
  static const String _shelfRemovedKey = 'shelf_removed_book_ids';
  static String? _cachedDeviceId;

  /// 未显式传入时复用 NetworkClient 单例，确保 Token 与 401 拦截器生效
  static Dio _getDio([Dio? customDio]) {
    return customDio ?? NetworkClient.getDio();
  }

  static Future<String> _getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('app_device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = 'flutter_${DateTime.now().millisecondsSinceEpoch}_${Platform.operatingSystem}';
      await prefs.setString('app_device_id', deviceId);
    }
    _cachedDeviceId = deviceId;
    return deviceId;
  }

  /// 1. 保存本地并完整上报 NAS（Dio 可选，默认使用 ApiConfig 单例）
  static Future<void> updateProgress({
    Dio? dio,
    required String bookId,
    required String title,
    required String filePath,
    required double progressPercent,
    String? locator,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final item = BookProgress(
      bookId: bookId,
      title: title,
      filePath: filePath,
      progress: progressPercent.clamp(0.0, 1.0),
      locator: locator ?? '',
      clientUpdatedAt: now,
    );

    // 写入本地 SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    Map<String, dynamic> map = rawMap != null ? jsonDecode(rawMap) : {};
    map[bookId] = item.toJson();
    await prefs.setString(_storageKey, jsonEncode(map));

    // 上报后端
    try {
      final client = _getDio(dio);
      final deviceId = await _getDeviceId();
      final requestData = {
        'book_id': bookId,
        'title': title,
        'file_path': filePath,
        'progress': progressPercent.clamp(0.0, 1.0),
        'locator': locator ?? '0',
        'device_id': deviceId,
        'device_name': Platform.operatingSystem,
        'client_updated_at': now,
      };

      final res = await client.post('/api/v1/sync/progress', data: requestData);
      AppLogger.log('✅ 进度同步成功: $title -> ${(progressPercent * 100).toStringAsFixed(1)}% (HTTP ${res.statusCode})');
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        AppLogger.log('ℹ️ 远端存在更新的阅读进度 (LWW)');
      } else {
        AppLogger.log('❌ 进度上报失败: ${e.response?.data ?? e.message}');
      }
    } catch (e) {
      AppLogger.log('❌ 进度上报异常: $e');
    }
  }

  /// 2. 冷启动/下拉刷新从 NAS 远端拉取全量记录并与本地合并
  static Future<List<BookProgress>> syncWithRemote([Dio? dio]) async {
    try {
      final client = _getDio(dio);
      final res = await client.get('/api/v1/sync/progress');
      AppLogger.log('📡 远端拉取进度响应: ${res.data}');

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> remoteList = [];
        if (res.data is Map && res.data['data'] is List) {
          remoteList = res.data['data'];
        } else if (res.data is List) {
          remoteList = res.data;
        }

        final prefs = await SharedPreferences.getInstance();
        final rawMap = prefs.getString(_storageKey);
        Map<String, dynamic> localMap = rawMap != null ? jsonDecode(rawMap) : {};
        final shelfRemoved = (prefs.getStringList(_shelfRemovedKey) ?? []).toSet();

        for (var raw in remoteList) {
          final remoteItem = BookProgress.fromJson(Map<String, dynamic>.from(raw));
          if (remoteItem.bookId.isEmpty) continue;
          if (shelfRemoved.contains(remoteItem.bookId)) continue;

          // 本地不存在或远端时间戳更新，则更新本地
          if (localMap.containsKey(remoteItem.bookId)) {
            final localItem = BookProgress.fromJson(localMap[remoteItem.bookId]);
            if (remoteItem.clientUpdatedAt >= localItem.clientUpdatedAt) {
              localMap[remoteItem.bookId] = remoteItem.toJson();
            }
          } else {
            localMap[remoteItem.bookId] = remoteItem.toJson();
          }
        }

        await prefs.setString(_storageKey, jsonEncode(localMap));
        AppLogger.log('✅ 远端书架合并完成，有效书籍记录数: ${localMap.length}');
      }
    } catch (e) {
      AppLogger.log('⚠️ 远端进度同步异常: $e');
    }

    return getAllLocalProgress();
  }

  /// 3. 获取单本书籍的本地阅读记录
  static Future<BookProgress?> getLocalProgress(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    if (rawMap == null) return null;
    final map = jsonDecode(rawMap) as Map<String, dynamic>;
    if (!map.containsKey(bookId)) return null;
    return BookProgress.fromJson(map[bookId]);
  }

  /// 切换到不同后端服务器时，清空本地书架相关数据（阅读进度、书签、书架移除标记），
  /// 避免上一台服务器的阅读记录残留到新的空服务器上。
  static Future<void> clearAllLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await prefs.remove(_shelfRemovedKey);
    final bookmarkKeys =
        prefs.getKeys().where((k) => k.startsWith('local_bookmarks_')).toList();
    for (final key in bookmarkKeys) {
      await prefs.remove(key);
    }
    AppLogger.log('🧹 已清空本地书架数据（切换服务器）');
  }

  /// 4. 获取本地所有阅读记录
  static Future<List<BookProgress>> getAllLocalProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    if (rawMap == null) return [];
    final map = jsonDecode(rawMap) as Map<String, dynamic>;
    final list = map.values.map((v) => BookProgress.fromJson(v)).toList();
    list.sort((a, b) => b.clientUpdatedAt.compareTo(a.clientUpdatedAt));
    return list;
  }

  /// 5. 彻底删除单本书籍数据（本地缓存、进度、书签，并同步通知远端）
  static Future<void> deleteBookEverything(String bookId, [Dio? dio]) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. 清理本地 SharedPreferences 阅读进度 Map
    final rawMap = prefs.getString(_storageKey);
    if (rawMap != null) {
      Map<String, dynamic> map = jsonDecode(rawMap);
      map.remove(bookId);
      await prefs.setString(_storageKey, jsonEncode(map));
    }

    // 2. 清理本地 SharedPreferences 书签记录
    await prefs.remove('local_bookmarks_$bookId');
    await _clearShelfRemovalFlag(prefs, bookId);

    // 3. 异步上报后端清除云端记录（不删除 NAS 原始文件）
    if (ApiConfig.isLoggedIn) {
      try {
        final client = _getDio(dio);
        final res = await client.post(
          '/api/v1/sync/delete',
          data: {
            'book_id': bookId,
          },
        );
        AppLogger.log('🗑️ 远端同步数据已清除: $bookId (HTTP ${res.statusCode})');
      } catch (e) {
        AppLogger.log('⚠️ 远端数据清除请求异常: $e');
      }
    }
  }

  /// 6. 从书架移除单本书籍：只清空本地进度与书签，云端记录保留，
  /// 重新加入书架时可从云端拉回历史进度继续阅读。
  static Future<void> removeFromShelfLocally(String bookId) async {
    final prefs = await SharedPreferences.getInstance();

    final rawMap = prefs.getString(_storageKey);
    if (rawMap != null) {
      final Map<String, dynamic> map = jsonDecode(rawMap);
      map.remove(bookId);
      await prefs.setString(_storageKey, jsonEncode(map));
    }
    await prefs.remove('local_bookmarks_$bookId');

    final removed = prefs.getStringList(_shelfRemovedKey) ?? [];
    if (!removed.contains(bookId)) {
      removed.add(bookId);
      await prefs.setStringList(_shelfRemovedKey, removed);
    }
    AppLogger.log('📤 已从书架移除并保留云端记录: $bookId');
  }

  /// 7. 书籍重新加入书架：解除屏蔽并从云端拉回此前的阅读进度
  static Future<void> restoreToShelf(String bookId, [Dio? dio]) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await _clearShelfRemovalFlag(prefs, bookId)) return;
    if (!ApiConfig.isLoggedIn) return;
    await syncWithRemote(dio);
    AppLogger.log('📥 已恢复书架书籍的云端阅读进度: $bookId');
  }

  /// 返回是否确实存在待清除的屏蔽标记
  static Future<bool> _clearShelfRemovalFlag(
    SharedPreferences prefs,
    String bookId,
  ) async {
    final removed = prefs.getStringList(_shelfRemovedKey) ?? [];
    if (!removed.remove(bookId)) return false;
    await prefs.setStringList(_shelfRemovedKey, removed);
    return true;
  }

  /// 8. 旧版本以“文件名”作为 bookId，新版本改用后端文件指纹。
  /// 首次以指纹打开某本书时，把仅存在旧键的记录迁移到新键，避免进度丢失。
  static Future<void> migrateLegacyBookId({
    required String legacyBookId,
    required String newBookId,
  }) async {
    if (legacyBookId == newBookId) return;

    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    if (rawMap != null) {
      final Map<String, dynamic> map = jsonDecode(rawMap);
      if (map.containsKey(legacyBookId) && !map.containsKey(newBookId)) {
        final legacy = BookProgress.fromJson(map[legacyBookId]);
        map[newBookId] = BookProgress(
          bookId: newBookId,
          title: legacy.title,
          filePath: legacy.filePath,
          progress: legacy.progress,
          locator: legacy.locator,
          clientUpdatedAt: legacy.clientUpdatedAt,
        ).toJson();
        map.remove(legacyBookId);
        await prefs.setString(_storageKey, jsonEncode(map));
        AppLogger.log('🔀 已迁移旧阅读进度: $legacyBookId -> $newBookId');
      }
    }

    final legacyBookmarks = prefs.getString('local_bookmarks_$legacyBookId');
    if (legacyBookmarks != null &&
        prefs.getString('local_bookmarks_$newBookId') == null) {
      await prefs.setString('local_bookmarks_$newBookId', legacyBookmarks);
      await prefs.remove('local_bookmarks_$legacyBookId');
      AppLogger.log('🔀 已迁移旧书签: $legacyBookId -> $newBookId');
    }
  }
}