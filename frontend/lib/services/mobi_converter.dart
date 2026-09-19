import 'dart:io';
import 'dart:isolate';
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_logger.dart';

/// 把 MOBI/AZW/AZW3/KF8 解包成 EPUB，复用现有的 EPUB 渲染与封面提取管线。
/// 转换结果按 bookId 缓存，二次打开直接命中缓存文件。
class MobiConverter {
  /// 转换后的 EPUB 缓存目录: ~/Documents/MobiConverted/
  static Future<Directory> _convertedDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDocDir.path, 'MobiConverted'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 将 MOBI 文件转成 EPUB 并返回缓存文件；失败返回 null。
  /// 解包属于 CPU 密集操作，放到后台 isolate 执行避免卡 UI。
  static Future<File?> toEpub(File mobiFile, String bookId) async {
    final dir = await _convertedDirectory();
    final target = File(p.join(dir.path, '$bookId.epub'));

    if (await target.exists() && await target.length() > 0) {
      return target;
    }

    if (!mobiFile.existsSync() || mobiFile.lengthSync() == 0) {
      AppLogger.log('⚠️ MOBI 文件不存在或为空: ${mobiFile.path}');
      return null;
    }

    try {
      final bytes = await mobiFile.readAsBytes();
      final epubBytes = await Isolate.run(() {
        final book = KindleBook.fromBytes(bytes);
        return book.toEpub();
      });
      await target.writeAsBytes(epubBytes, flush: true);
      return target;
    } catch (e) {
      AppLogger.log('❌ MOBI 转 EPUB 失败: $e');
      return null;
    }
  }
}
