import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/progress_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _progressKey = 'local_reading_progress_map';
const String _shelfRemovedKey = 'shelf_removed_book_ids';

Map<String, dynamic> _progressEntry({
  required String bookId,
  double progress = 0.42,
  String locator = '1024',
}) => {
      'book_id': bookId,
      'title': '示例书',
      'file_path': '/books/示例书.txt',
      'progress': progress,
      'locator': locator,
      'client_updated_at': 1700000000000,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ProgressSyncService 书架移除', () {
    test('removeFromShelfLocally 清掉本地进度与书签并记录屏蔽标记', () async {
      SharedPreferences.setMockInitialValues({
        _progressKey: jsonEncode({'fp-1': _progressEntry(bookId: 'fp-1')}),
        'local_bookmarks_fp-1': <String>['{"id":"b1"}'],
      });

      await ProgressSyncService.removeFromShelfLocally('fp-1');

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(_progressKey)!), isEmpty);
      expect(prefs.getStringList('local_bookmarks_fp-1'), isNull);
      expect(prefs.getStringList(_shelfRemovedKey), ['fp-1']);
      expect(await ProgressSyncService.getLocalProgress('fp-1'), isNull);
    });

    test('重复移除不会写入重复的屏蔽标记', () async {
      await ProgressSyncService.removeFromShelfLocally('fp-1');
      await ProgressSyncService.removeFromShelfLocally('fp-1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_shelfRemovedKey), ['fp-1']);
    });

    test('restoreToShelf 未登录时仅解除屏蔽标记', () async {
      SharedPreferences.setMockInitialValues({
        _shelfRemovedKey: <String>['fp-1', 'fp-2'],
      });

      await ProgressSyncService.restoreToShelf('fp-1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_shelfRemovedKey), ['fp-2']);
    });

    test('deleteBookEverything 顺带清掉遗留的屏蔽标记', () async {
      SharedPreferences.setMockInitialValues({
        _progressKey: jsonEncode({'fp-1': _progressEntry(bookId: 'fp-1')}),
        _shelfRemovedKey: <String>['fp-1'],
      });

      await ProgressSyncService.deleteBookEverything('fp-1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(_shelfRemovedKey), isEmpty);
      expect(jsonDecode(prefs.getString(_progressKey)!), isEmpty);
    });

    test('clearAllLocal 清空进度、书签与屏蔽标记', () async {
      SharedPreferences.setMockInitialValues({
        _progressKey: jsonEncode({
          'fp-1': _progressEntry(bookId: 'fp-1'),
          'fp-2': _progressEntry(bookId: 'fp-2'),
        }),
        _shelfRemovedKey: <String>['fp-3'],
        'local_bookmarks_fp-1': <String>['{"id":"b1"}'],
        'local_bookmarks_fp-2': <String>['{"id":"b2"}'],
        'unrelated_key': 'keep-me',
      });

      await ProgressSyncService.clearAllLocal();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_progressKey), isNull);
      expect(prefs.getStringList(_shelfRemovedKey), isNull);
      expect(prefs.getStringList('local_bookmarks_fp-1'), isNull);
      expect(prefs.getStringList('local_bookmarks_fp-2'), isNull);
      // 非书架相关的键不应被误删
      expect(prefs.getString('unrelated_key'), 'keep-me');
      expect(await ProgressSyncService.getAllLocalProgress(), isEmpty);
    });
  });
}
