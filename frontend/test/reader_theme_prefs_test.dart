import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/reader_theme.dart';
import 'package:nas_reader/services/reader_theme_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ReaderThemePrefs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('无历史记录时返回羊皮纸1', () async {
      expect(await ReaderThemePrefs.load(), ReaderThemes.parchment);
    });

    test('save 后 load 能取回同一个主题', () async {
      await ReaderThemePrefs.save(ReaderThemes.night);
      expect(await ReaderThemePrefs.load(), ReaderThemes.night);
    });

    test('每个内置主题都能完整往返', () async {
      for (final theme in ReaderThemes.all) {
        await ReaderThemePrefs.save(theme);
        expect(await ReaderThemePrefs.load(), same(theme));
      }
    });

    test('已下线主题的旧存档退回羊皮纸1', () async {
      SharedPreferences.setMockInitialValues({'reader_theme_name': '护眼绿'});
      expect(await ReaderThemePrefs.load(), ReaderThemes.parchment);
    });

    test('空字符串存档退回羊皮纸1', () async {
      SharedPreferences.setMockInitialValues({'reader_theme_name': ''});
      expect(await ReaderThemePrefs.load(), ReaderThemes.parchment);
    });

    test('resolveByName 按名称取回同一实例', () {
      for (final theme in ReaderThemes.all) {
        expect(ReaderThemePrefs.resolveByName(theme.name), same(theme));
      }
    });
  });
}
