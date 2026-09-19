import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/book_fingerprint.dart';
import '../core/book_format.dart';
import '../core/network_client.dart';
import '../models/favorite_book.dart';
import '../readers/epub_reader_page.dart';
import '../readers/pdf_reader_page.dart';
import '../readers/stream_txt_reader_page.dart';
import '../services/app_logger.dart';
import '../services/favorite_service.dart';
import '../services/mobi_converter.dart';
import '../services/progress_sync_service.dart';

class FavoritesPage extends StatefulWidget {
  final Dio? dio;

  const FavoritesPage({super.key, this.dio});

  @override
  State<FavoritesPage> createState() => FavoritesPageState();
}

class FavoritesPageState extends State<FavoritesPage> {
  List<FavoriteBook> _favorites = [];
  bool _isLoading = true;

  Dio get _dio => widget.dio ?? NetworkClient.getDio();

  @override
  void initState() {
    super.initState();
    loadFavorites();
    FavoriteService.revision.addListener(_onFavoritesChanged);
  }

  @override
  void dispose() {
    FavoriteService.revision.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) loadFavorites();
  }

  Future<void> loadFavorites() async {
    final list = await FavoriteService.getAll();
    if (!mounted) return;
    setState(() {
      _favorites = list;
      _isLoading = false;
    });
  }

  /// 下拉刷新：先与后端双向合并，未登录/离线时自动回退本地
  Future<void> _refreshFavorites() async {
    final list = await FavoriteService.syncWithServer();
    if (!mounted) return;
    setState(() {
      _favorites = list;
      _isLoading = false;
    });
  }

  Future<void> _handleRemoveFavorite(FavoriteBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(
          '确定要将《${book.title}》从收藏夹移除吗？\n\n'
          '• 仅移除收藏标记\n'
          '• 阅读进度、本地缓存与 NAS 原始文件均不受影响',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认取消收藏'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await FavoriteService.remove(book.bookId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已取消收藏《${book.title}》'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 定位本地缓存文件；不存在则从 NAS 下载
  Future<File?> _ensureLocalFile(FavoriteBook book) async {
    final appDir = await getApplicationDocumentsDirectory();
    final booksDir = Directory(p.join(appDir.path, 'books'));
    if (!booksDir.existsSync()) booksDir.createSync(recursive: true);

    final cacheName = BookCacheNaming.buildFileName(
      bookId: book.bookId,
      originalName: book.fileName,
    );
    final target = File(p.join(booksDir.path, cacheName));
    if (target.existsSync() && target.lengthSync() > 0) return target;

    // 兼容旧版无指纹前缀的缓存文件
    final legacy = File(p.join(booksDir.path, book.fileName));
    if (legacy.existsSync() && legacy.lengthSync() > 0) return legacy;

    if (book.remotePath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('缺少远端路径，无法下载此书')),
        );
      }
      return null;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在从 NAS 下载《${book.title}》...')),
      );
    }

    final downloadPath =
        book.remotePath.startsWith('/') ? book.remotePath : '/${book.remotePath}';
    try {
      await _dio.download(
        '/api/v1/files/download',
        target.path,
        queryParameters: {'path': downloadPath},
      );
      return target;
    } catch (e) {
      AppLogger.log('❌ 收藏夹下载书籍失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
        );
      }
      return null;
    }
  }

  Future<void> _openBook(FavoriteBook book) async {
    final ext = book.extension;
    final format = BookFormat.fromExtension(ext);
    if (format == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂不支持此格式阅读，目前支持 ${BookFormat.labels}')),
      );
      return;
    }

    final file = await _ensureLocalFile(book);
    if (file == null || !mounted) return;

    // MOBI 先解包成 EPUB，再复用 EPUB 渲染管线
    File readerFile = file;
    if (format == BookFormat.mobi) {
      final epubFile = await MobiConverter.toEpub(file, book.bookId);
      if (!mounted) return;
      if (epubFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MOBI 解析失败，可能为加密或不受支持的变体')),
        );
        return;
      }
      readerFile = epubFile;
    }
    final bool cfiBased = format == BookFormat.epub || format == BookFormat.mobi;

    // 曾从书架移除过的书，重新打开时把云端进度拉回本地
    await ProgressSyncService.restoreToShelf(book.bookId, _dio);

    final saved = await ProgressSyncService.getLocalProgress(book.bookId);

    // 尚未加入书架的书，写入一条初始进度记录使其出现在本地书架
    if (saved == null) {
      await ProgressSyncService.updateProgress(
        dio: _dio,
        bookId: book.bookId,
        title: book.title,
        filePath: book.remotePath,
        progressPercent: 0.0,
        locator: cfiBased ? '' : '0',
      );
    }

    if (!mounted) return;

    void reportProgress(String locator, double progress) {
      ProgressSyncService.updateProgress(
        dio: _dio,
        bookId: book.bookId,
        title: book.title,
        filePath: book.remotePath,
        progressPercent: progress,
        locator: locator,
      );
    }

    final Widget readerPage;
    switch (format) {
      case BookFormat.txt:
        readerPage = StreamTxtReaderPage(
          bookId: book.bookId,
          file: file,
          title: book.title,
          initialByteOffset: saved?.txtByteOffset ?? 0,
          onProgressChanged: (byteOffset, progress) =>
              reportProgress(byteOffset.toString(), progress),
        );
      case BookFormat.epub:
      case BookFormat.mobi:
        readerPage = EpubReaderPage(
          bookId: book.bookId,
          file: readerFile,
          title: book.title,
          initialCfi: saved?.epubCfi,
          initialProgress: saved?.progress ?? 0.0,
          onProgressChanged: reportProgress,
        );
      case BookFormat.pdf:
        readerPage = PdfReaderPage(
          bookId: book.bookId,
          file: file,
          title: book.title,
          initialPage: saved?.pdfPage ?? 0,
          initialProgress: saved?.progress ?? 0.0,
          onProgressChanged: (pageIndex, progress) =>
              reportProgress(pageIndex.toString(), progress),
        );
    }

    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (context, animation, secondaryAnimation) => readerPage,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏夹'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFavorites,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_favorites.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          const Center(
            child: Text(
              '收藏夹还是空的\n在「本地书架」或「NAS 书库」点击书籍图标上的 ☆ 即可收藏',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _favorites.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = _favorites[index];
        final format = BookFormat.fromExtension(book.extension);

        return ListTile(
          leading: Icon(
            format?.icon ?? Icons.insert_drive_file,
            color: format?.color ?? Colors.grey,
            size: 28,
          ),
          title: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            book.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          trailing: Icon(Icons.star, color: Colors.amber.shade600, size: 20),
          onTap: () => _openBook(book),
          onLongPress: () => _handleRemoveFavorite(book),
        );
      },
    );
  }
}
