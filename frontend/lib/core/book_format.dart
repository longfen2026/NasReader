import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 阅读器可打开的电子书格式，前后端白名单需保持一致
/// （后端见 `handlers.IsSupportedBookExt`）。
enum BookFormat {
  txt('.txt', Icons.description, Icons.description_outlined, Colors.blue),
  epub('.epub', Icons.menu_book, Icons.menu_book_outlined, Colors.green),
  mobi('.mobi', Icons.auto_stories, Icons.auto_stories_outlined, Colors.deepOrange),
  pdf('.pdf', Icons.picture_as_pdf, Icons.picture_as_pdf_outlined, Colors.redAccent);

  final String extension;
  final IconData icon;
  final IconData outlinedIcon;
  final Color color;

  const BookFormat(this.extension, this.icon, this.outlinedIcon, this.color);

  /// 支持格式的展示文案，如 `TXT / EPUB / PDF`
  static String get labels =>
      BookFormat.values.map((e) => e.extension.substring(1).toUpperCase()).join(' / ');

  /// 按扩展名（含点号，大小写不敏感）解析格式，不支持时返回 null
  static BookFormat? fromExtension(String? extension) {
    if (extension == null || extension.isEmpty) return null;
    final normalized = extension.toLowerCase();
    for (final format in BookFormat.values) {
      if (format.extension == normalized) return format;
    }
    return null;
  }

  static BookFormat? fromFileName(String fileName) =>
      fromExtension(p.extension(fileName));

  static bool isSupported(String fileName) => fromFileName(fileName) != null;
}
