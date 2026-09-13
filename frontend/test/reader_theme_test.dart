import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/reader_theme.dart';

void main() {
  test('羊皮纸主题使用对应的纹理背景图', () {
    expect(ReaderThemes.parchment.name, '羊皮纸1');
    expect(ReaderThemes.parchment.backgroundImage, 'assets/readbg_1.png');

    expect(ReaderThemes.parchment2.name, '羊皮纸2');
    expect(ReaderThemes.parchment2.backgroundImage, 'assets/readbg_2.jpg');
    // 图片加载失败时以底色兜底，两个羊皮纸观感需保持一致
    expect(ReaderThemes.parchment2.bgColor, ReaderThemes.parchment.bgColor);
    expect(ReaderThemes.parchment2.textColor, ReaderThemes.parchment.textColor);
  });

  test('主题名称唯一，选中判定可仅依赖 name', () {
    final names = ReaderThemes.all.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
    expect(names, ['羊皮纸1', '羊皮纸2', '夜空', '黑夜', '纯白', '纯黑']);
  });

  test('只有纯白与纯黑主题保持纯色', () {
    final withImage = ReaderThemes.all.where((t) => t.backgroundImage != null);
    expect(withImage.map((t) => t.name), ['羊皮纸1', '羊皮纸2', '夜空', '黑夜']);
    expect(ReaderThemes.white.backgroundImage, isNull);
  });

  test('纯黑主题使用纯黑背景与浅色文字', () {
    expect(ReaderThemes.black.name, '纯黑');
    expect(ReaderThemes.black.bgColor, const Color(0xFF000000));
    expect(ReaderThemes.black.backgroundImage, isNull);
    expect(ReaderThemes.black.textColor, isNotNull);
  });

  test('所有主题背景图均已打进 asset bundle', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final theme
        in ReaderThemes.all.where((theme) => theme.backgroundImage != null)) {
      final data = await rootBundle.load(theme.backgroundImage!);
      expect(data.lengthInBytes, greaterThan(0));
    }
  });
}
