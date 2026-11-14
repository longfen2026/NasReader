// lib/services/book_reconcile_service.dart
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/network_client.dart';
import 'app_logger.dart';
import 'favorite_service.dart';
import 'progress_sync_service.dart';

/// 书籍更新（云端文件被替换为名称基本一致的新文件）后的阅读记录对账服务。
/// 后端以内容指纹（book_id）标识书籍，文件更新后指纹变化、旧记录沦为孤儿；
/// 本服务在书架加载时调用后端对账接口，把孤儿记录迁移到匹配到的新文件上。
class BookReconcileService {
  static const String _reconcilePath = '/api/v1/sync/reconcile';

  /// 用户“忽略”歧义候选的记忆（prefs key）：old_book_id -> 候选签名。
  /// 候选集合变化（用户新增了文件）时签名不再匹配，会重新提示。
  static const String _dismissedKey = 'reconcile_dismissed_map';

  /// 未显式传入时复用 NetworkClient 单例，确保 Token 与 401 拦截器生效
  static Dio _getDio([Dio? customDio]) => customDio ?? NetworkClient.getDio();

  /// 对账入口：调用后端扫描孤儿记录并自动迁移，返回迁移结果与待确认的歧义项
  static Future<ReconcileResult> reconcile([Dio? dio]) async {
    final res = await _getDio(dio).post(_reconcilePath);
    final body = res.data;
    if (body is! Map) return ReconcileResult.empty();
    if (body['status'] == 'index_not_ready') {
      AppLogger.log('⏳ 书库索引尚未构建完成，本次跳过对账');
      return ReconcileResult.empty(indexNotReady: true);
    }
    return ReconcileResult.fromJson(Map<String, dynamic>.from(body));
  }

  /// 用户在歧义弹窗中确认后，执行迁移并应用本地记录迁移
  static Future<ReconcileMigration?> confirm(
    String oldBookId,
    String newBookId, [
    Dio? dio,
  ]) async {
    final res = await _getDio(dio).post(
      '$_reconcilePath/confirm',
      data: {'old_book_id': oldBookId, 'new_book_id': newBookId},
    );
    final body = res.data;
    if (body is! Map || body['migration'] is! Map) return null;
    final migration = ReconcileMigration.fromJson(
      Map<String, dynamic>.from(body['migration'] as Map),
    );
    await applyMigration(migration);
    return migration;
  }

  /// 应用一条已确认的迁移：本地进度/书签/收藏键全部换到新 bookId
  static Future<void> applyMigration(ReconcileMigration migration) async {
    await ProgressSyncService.migrateBookRecord(
      oldBookId: migration.oldBookId,
      newBookId: migration.newBookId,
      newFilePath: migration.newFilePath,
      newTitle: migration.title,
    );
    await FavoriteService.migrateBookId(
      migration.oldBookId,
      migration.newBookId,
      newTitle: migration.title,
      newFileName: migration.newFilePath.isEmpty
          ? null
          : migration.newFilePath.split('/').last,
      newRemotePath: migration.newFilePath,
    );
  }

  /// 候选集合签名：候选变化时旧签名不再匹配，需重新提示用户
  static String candidateSignature(Iterable<ReconcileCandidate> candidates) {
    final ids = candidates.map((c) => c.bookId).toList()..sort();
    return ids.join('|');
  }

  /// 该孤儿记录的候选是否已被用户忽略过
  static Future<bool> isDismissed(
    String oldBookId,
    Iterable<ReconcileCandidate> candidates,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_dismissedKey);
    if (raw == null) return false;
    final map = jsonDecode(raw);
    if (map is! Map) return false;
    return map[oldBookId] == candidateSignature(candidates);
  }

  /// 记录用户对某条歧义候选的忽略选择
  static Future<void> rememberDismissed(
    String oldBookId,
    Iterable<ReconcileCandidate> candidates,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_dismissedKey);
    final Map<String, dynamic> map =
        raw != null && jsonDecode(raw) is Map ? Map.from(jsonDecode(raw)) : {};
    map[oldBookId] = candidateSignature(candidates);
    await prefs.setString(_dismissedKey, jsonEncode(map));
  }
}

class ReconcileCandidate {
  final String bookId;
  final String name;
  final String path;
  final String extension;

  const ReconcileCandidate({
    required this.bookId,
    required this.name,
    required this.path,
    required this.extension,
  });

  factory ReconcileCandidate.fromJson(Map<String, dynamic> json) =>
      ReconcileCandidate(
        bookId: (json['book_id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        extension: (json['extension'] ?? '').toString(),
      );
}

class ReconcileMigration {
  final String oldBookId;
  final String newBookId;
  final String newFilePath;
  final String title;

  const ReconcileMigration({
    required this.oldBookId,
    required this.newBookId,
    required this.newFilePath,
    required this.title,
  });

  factory ReconcileMigration.fromJson(Map<String, dynamic> json) =>
      ReconcileMigration(
        oldBookId: (json['old_book_id'] ?? '').toString(),
        newBookId: (json['new_book_id'] ?? '').toString(),
        newFilePath: (json['new_file_path'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
      );
}

class ReconcilePending {
  final String oldBookId;
  final String title;
  final String oldFilePath;
  final List<ReconcileCandidate> candidates;

  const ReconcilePending({
    required this.oldBookId,
    required this.title,
    required this.oldFilePath,
    required this.candidates,
  });

  factory ReconcilePending.fromJson(Map<String, dynamic> json) =>
      ReconcilePending(
        oldBookId: (json['old_book_id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        oldFilePath: (json['old_file_path'] ?? '').toString(),
        candidates: ((json['candidates'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReconcileCandidate.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class ReconcileResult {
  final bool indexNotReady;
  final List<ReconcileMigration> migrated;
  final List<ReconcilePending> pending;

  const ReconcileResult({
    this.indexNotReady = false,
    this.migrated = const [],
    this.pending = const [],
  });

  factory ReconcileResult.empty({bool indexNotReady = false}) =>
      ReconcileResult(indexNotReady: indexNotReady);

  factory ReconcileResult.fromJson(Map<String, dynamic> json) =>
      ReconcileResult(
        migrated: ((json['migrated'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) =>
                ReconcileMigration.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        pending: ((json['pending'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReconcilePending.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}
