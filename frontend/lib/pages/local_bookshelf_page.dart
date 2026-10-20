import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/book_fingerprint.dart';
import '../core/book_format.dart';
import '../core/network_client.dart';
import '../services/progress_sync_service.dart';
import '../services/favorite_service.dart';
import '../services/mobi_converter.dart';
import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../readers/pdf_reader_page.dart';
import '../services/app_logger.dart';
import '../widgets/book_leading_icon.dart';

class BookshelfItem {
  final String bookId;
  final String title;
  final String fileName;
  final String extension;
  final File? localFile;
  final String remotePath;
  final double progressPercent;
  final String? epubCfi;
  final int? txtByteOffset;
  final int pdfPage;
  final DateTime lastReadTime;

  /// 本地缓存文件体积，仅在已下载时有值
  final int fileSizeBytes;

  bool get isDownloaded => localFile != null && localFile!.existsSync();

  BookshelfItem({
    required this.bookId,
    required this.title,
    required this.fileName,
    required this.extension,
    this.localFile,
    required this.remotePath,
    required this.progressPercent,
    this.epubCfi,
    this.txtByteOffset,
    this.pdfPage = 0,
    required this.lastReadTime,
    this.fileSizeBytes = 0,
  });
}

/// 书架体积展示统一走 MB，不足 0.1MB 时降级为 KB 避免显示 0.0MB
String formatBookSize(int bytes) {
  if (bytes <= 0) return '';
  const int mb = 1024 * 1024;
  if (bytes < mb ~/ 10) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  return '${(bytes / mb).toStringAsFixed(1)}MB';
}

class LocalBookshelfPage extends StatefulWidget {
  final Dio? dio;

  const LocalBookshelfPage({super.key, this.dio});

  @override
  State<LocalBookshelfPage> createState() => LocalBookshelfPageState();
}

class LocalBookshelfPageState extends State<LocalBookshelfPage>
    with WidgetsBindingObserver {
  List<BookshelfItem> _books = [];
  Set<String> _favoriteIds = {};
  bool _isLoading = true;

  /// 当前分组：true=本地（已缓存），false=云端（有阅读记录但未缓存）。默认本地。
  bool _showLocalGroup = true;

  /// 本地分组：已下载缓存到本地的书
  List<BookshelfItem> get _localBooks =>
      _books.where((b) => b.isDownloaded).toList();

  /// 云端分组：有阅读记录但尚未缓存到本地的书
  List<BookshelfItem> get _cloudBooks =>
      _books.where((b) => !b.isDownloaded).toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FavoriteService.revision.addListener(_refreshFavoriteIds);
    loadLocalBooks();
  }

  @override
  void dispose() {
    FavoriteService.revision.removeListener(_refreshFavoriteIds);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshFavoriteIds() async {
    final ids = await FavoriteService.getFavoriteIds();
    if (mounted) setState(() => _favoriteIds = ids);
  }

  Future<void> _toggleFavorite(BookshelfItem book) async {
    final added = await FavoriteService.toggle(
      bookId: book.bookId,
      title: book.title,
      fileName: book.fileName,
      remotePath: book.remotePath,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已收藏《${book.title}》' : '已取消收藏《${book.title}》'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      loadLocalBooks();
    }
  }

  /// 云端记录对应的本地缓存可能已被清理，statSync 失败时按未知体积处理
  int _fileSizeOf(File? file) {
    if (file == null) return 0;
    try {
      return file.statSync().size;
    } catch (_) {
      return 0;
    }
  }

  Future<void> loadLocalBooks() async {
    try {
      // 1. 若有网络则尝试同步一次远端进度列表
      if (widget.dio != null) {
        await ProgressSyncService.syncWithRemote(widget.dio!);
      }
      // 书架是启动首页，在此拉一次账号维度的收藏夹（未登录时内部会直接返回本地）
      await FavoriteService.syncWithServer();

      final progressList = await ProgressSyncService.getAllLocalProgress();

      // 2. 扫描本地已缓存的书籍文件
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!booksDir.existsSync()) booksDir.createSync(recursive: true);

      // 缓存文件名形如 `<指纹>__<原始文件名>`，旧版本为纯文件名。
      // 分别按 bookId 与原始文件名建立索引，兼容两种命名。
      final Map<String, File> filesByBookId = {};
      final Map<String, File> filesByName = {};
      for (var f in booksDir.listSync()) {
        if (f is File) {
          final base = p.basename(f.path);
          filesByBookId[BookCacheNaming.extractBookId(base)] = f;
          filesByName[BookCacheNaming.extractOriginalName(base)] = f;
        }
      }

      final Map<String, BookshelfItem> mergedItems = {};

      // 3. 先加入远端记录（bookId 为文件指纹，文件名从远端路径推导）
      for (var pItem in progressList) {
        final fileName = pItem.fileName;
        final ext = p.extension(fileName).toLowerCase();
        final localFile = filesByBookId[pItem.bookId] ?? filesByName[fileName];

        mergedItems[pItem.bookId] = BookshelfItem(
          bookId: pItem.bookId,
          title: pItem.title.isNotEmpty
              ? pItem.title
              : p.basenameWithoutExtension(fileName),
          fileName: fileName,
          extension: ext,
          localFile: localFile,
          remotePath: pItem.filePath,
          progressPercent: pItem.progress,
          epubCfi: pItem.epubCfi,
          txtByteOffset: pItem.txtByteOffset,
          pdfPage: pItem.pdfPage,
          lastReadTime:
              DateTime.fromMillisecondsSinceEpoch(pItem.clientUpdatedAt),
          fileSizeBytes: _fileSizeOf(localFile),
        );
      }

      // 4. 补充本地已存在但尚未有远端进度的离线书籍
      filesByBookId.forEach((bookId, file) {
        if (!mergedItems.containsKey(bookId)) {
          final fileName =
              BookCacheNaming.extractOriginalName(p.basename(file.path));
          final ext = p.extension(fileName).toLowerCase();
          if (BookFormat.fromExtension(ext) != null) {
            final stat = file.statSync();
            mergedItems[bookId] = BookshelfItem(
              bookId: bookId,
              title: p.basenameWithoutExtension(fileName),
              fileName: fileName,
              extension: ext,
              localFile: file,
              remotePath: '',
              progressPercent: 0.0,
              lastReadTime: stat.modified,
              fileSizeBytes: stat.size,
            );
          }
        }
      });

      final resultList = mergedItems.values.toList()
        ..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

      final favoriteIds = await FavoriteService.getFavoriteIds();

      if (mounted) {
        setState(() {
          _books = resultList;
          _favoriteIds = favoriteIds;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.log('❌ 刷新书架异常: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 行尾三点菜单：收藏、移出书架、扔到垃圾箱
  Widget _buildBookActionMenu(BookshelfItem book) {
    final isFavorite = _favoriteIds.contains(book.bookId);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.grey),
      tooltip: '更多操作',
      onSelected: (action) async {
        switch (action) {
          case 'favorite':
            await _confirmToggleFavorite(book, isFavorite);
            break;
          case 'remove':
            await _handleDeleteBook(book);
            break;
          case 'trash':
            await _handleMoveToTrash(book);
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'favorite',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              isFavorite ? Icons.star_border : Icons.star,
              color: Colors.amber.shade700,
            ),
            title: Text(isFavorite ? '移出收藏' : '加入收藏'),
          ),
        ),
        const PopupMenuItem(
          value: 'remove',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_sweep_outlined, color: Colors.orange),
            title: Text('移出书架'),
          ),
        ),
        const PopupMenuItem(
          value: 'trash',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text('扔到垃圾箱'),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmToggleFavorite(
      BookshelfItem book, bool isFavorite) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFavorite ? '移出收藏' : '加入收藏'),
        content: Text(
          isFavorite
              ? '确定要把《${book.title}》从收藏夹移除吗？'
              : '确定要把《${book.title}》加入收藏夹吗？',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isFavorite ? '移出收藏' : '收藏'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;
    await _toggleFavorite(book);
  }

  /// 移入 NAS 垃圾箱：先让服务端搬移原始文件，再清理本地书架痕迹
  Future<void> _handleMoveToTrash(BookshelfItem book) async {
    final hasRemote = book.remotePath.isNotEmpty;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            const Text('移入垃圾箱', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(
          '确定要把《${book.title}》移入 NAS 垃圾箱吗？\n\n'
          '${hasRemote ? '• NAS 书库中的原始文件会一并移入垃圾箱\n' : '• 该书未关联 NAS 书库文件，仅清理本地记录\n'}'
          '• 本地缓存、阅读进度、书签与收藏将一并清除\n'
          '• 可在“设置 - 垃圾箱”中查看或恢复文件',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('移入垃圾箱', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    final dio = widget.dio ?? NetworkClient.getDio();
    try {
      if (hasRemote) {
        final remotePath = book.remotePath.startsWith('/')
            ? book.remotePath
            : '/${book.remotePath}';
        await dio.post('/api/v1/files/trash', data: {'path': remotePath});
      }

      if (book.localFile != null && await book.localFile!.exists()) {
        await book.localFile!.delete();
      }
      await FavoriteService.remove(book.bookId);
      await ProgressSyncService.deleteBookEverything(book.bookId, dio);

      await loadLocalBooks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把《${book.title}》移入垃圾箱'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLogger.log('❌ 移入垃圾箱失败: ${book.remotePath} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('移入垃圾箱失败，请检查网络或服务端权限'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// 从书架移除（只清本地缓存与本地进度/书签，云端记录保留）
  Future<void> _handleDeleteBook(BookshelfItem book) async {
    var removeFromCloud = false;
    final bool? removeCloudChoice = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('从书架移除',
              style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '确定要从书架移除《${book.title}》吗？\n\n'
                '• 本地缓存文件与本地阅读进度、书签将被清理\n'
                '• 默认保留云端阅读进度与书签，重新加入书架后可继续阅读\n'
                '• NAS 原始文件不受影响，可随时重新下载',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: removeFromCloud,
                onChanged: (value) =>
                    setDialogState(() => removeFromCloud = value ?? false),
                title: const Text(
                  '同时从云端移除',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                subtitle: const Text(
                  '删除云端阅读记录和对应书签，不影响收藏',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
              ),
              onPressed: () => Navigator.pop(ctx, removeFromCloud),
              child: const Text('确认移除'),
            ),
          ],
        ),
      ),
    );

    if (removeCloudChoice == null || !mounted) return;

    try {
      if (removeCloudChoice) {
        await ProgressSyncService.removeBookReadingDataFromCloud(
          book.bookId,
          widget.dio,
        );
      }

      // 1. 删除本地物理缓存文件
      if (book.localFile != null && await book.localFile!.exists()) {
        await book.localFile!.delete();
      }

      // 2. 清理本地记录，并屏蔽远端同步把它拉回书架
      await ProgressSyncService.removeFromShelfLocally(book.bookId);

      // 3. 重新加载书架视图
      await loadLocalBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              removeCloudChoice
                  ? '已从书架及云端移除《${book.title}》的阅读记录和书签'
                  : '已从书架移除《${book.title}》',
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      AppLogger.log('❌ 移除书架异常: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('移除失败: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _openOrDownloadBook(BookshelfItem book) async {
    File targetFile;

    // 若新设备尚未下载此书，先从 NAS 远端下载
    if (!book.isDownloaded) {
      if (widget.dio == null || book.remotePath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接到 NAS 或缺少远端路径，无法下载此书')),
        );
        return;
      }

      final appDir = await getApplicationDocumentsDirectory();
      final savePath = p.join(
        appDir.path,
        'books',
        BookCacheNaming.buildFileName(
            bookId: book.bookId, originalName: book.fileName),
      );
      final downloadPath = book.remotePath.startsWith('/')
          ? book.remotePath
          : '/${book.remotePath}';
      final downloadProgress = ValueNotifier<double>(0.0);
      final cancelToken = CancelToken();
      var progressDialogVisible = true;

      try {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              cancelToken.cancel('用户取消下载');
            },
            child: Dialog(
              backgroundColor: Theme.of(dialogContext).cardColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(strokeWidth: 3.5),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '正在下载《${book.title}》',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<double>(
                      valueListenable: downloadProgress,
                      builder: (context, progress, _) => Column(
                        children: [
                          LinearProgressIndicator(
                            value: progress > 0 ? progress : null,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            progress > 0
                                ? '${(progress * 100).toStringAsFixed(1)}%'
                                : '正在从 NAS 建立传输连接...',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        cancelToken.cancel('用户取消');
                        progressDialogVisible = false;
                        Navigator.pop(dialogContext);
                      },
                      child: const Text('取消下载'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await Directory(p.dirname(savePath)).create(recursive: true);
        await widget.dio!.download(
          '/api/v1/files/download',
          savePath,
          queryParameters: {'path': downloadPath},
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              downloadProgress.value = (received / total).clamp(0.0, 1.0);
            }
          },
        );
        if (mounted && progressDialogVisible) {
          progressDialogVisible = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
        targetFile = File(savePath);
      } catch (e) {
        if (mounted && progressDialogVisible) {
          progressDialogVisible = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
        final isCanceled = e is DioException && CancelToken.isCancel(e);
        if (!isCanceled && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
          );
        }
        return;
      } finally {
        downloadProgress.dispose();
      }
    } else {
      targetFile = book.localFile!;
    }

    if (!mounted) return;
    final initialOffset = book.txtByteOffset ?? 0;
    final initialCfi = book.epubCfi;

    if (book.extension == '.mobi') {
      final epubFile = await MobiConverter.toEpub(targetFile, book.bookId);
      if (!mounted) return;
      if (epubFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MOBI 解析失败，可能为加密或不受支持的变体')),
        );
        return;
      }
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) =>
              EpubReaderPage(
            bookId: book.bookId,
            file: epubFile,
            title: book.title,
            initialCfi: initialCfi,
            initialProgress: book.progressPercent,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                locator: cfi,
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => loadLocalBooks());
    } else if (book.extension == '.txt') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) =>
              StreamTxtReaderPage(
            bookId: book.bookId,
            file: targetFile,
            title: book.title,
            initialByteOffset: initialOffset,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                locator: byteOffset.toString(),
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => loadLocalBooks());
    } else if (book.extension == '.epub') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) =>
              EpubReaderPage(
            bookId: book.bookId,
            file: targetFile,
            title: book.title,
            initialCfi: initialCfi,
            initialProgress: book.progressPercent,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                locator: cfi,
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => loadLocalBooks());
    } else if (book.extension == '.pdf') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) =>
              PdfReaderPage(
            bookId: book.bookId,
            file: targetFile,
            title: book.title,
            initialPage: book.pdfPage,
            initialProgress: book.progressPercent,
            onProgressChanged: (pageIndex, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                locator: pageIndex.toString(),
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => loadLocalBooks());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showLocalGroup ? '本地书架' : '云端书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '同步远端进度',
            onPressed: loadLocalBooks,
          ),
          IconButton(
            icon: Icon(
                _showLocalGroup ? Icons.cloud_outlined : Icons.phone_android),
            tooltip: _showLocalGroup ? '切换到云端' : '切换到本地',
            onPressed: () => setState(() => _showLocalGroup = !_showLocalGroup),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadLocalBooks,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final books = _showLocalGroup ? _localBooks : _cloudBooks;

    if (books.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Text(
              _showLocalGroup
                  ? '本地暂无已缓存书籍\n可前往「NAS 书库」下载，或切换到云端'
                  : '云端暂无未缓存的阅读记录',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, height: 1.5),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: books.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = books[index];
        final format = BookFormat.fromExtension(book.extension);

        return ListTile(
          // 48px 的三点按钮内部自带 12px 视觉留白，右侧内边距取 4px 即为 16px
          contentPadding: const EdgeInsets.only(left: 16, right: 4),
          leading: BookLeadingIcon(
            icon: format?.icon ?? Icons.insert_drive_file,
            iconColor: format?.color ?? Colors.grey,
            isFavorite: _favoriteIds.contains(book.bookId),
          ),
          title: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Row(
            children: [
              Text(
                '已读 ${(book.progressPercent * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12, color: Colors.brown),
              ),
              if (book.fileSizeBytes > 0) ...[
                const SizedBox(width: 8),
                Text(
                  formatBookSize(book.fileSizeBytes),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              const SizedBox(width: 8),
              if (!book.isDownloaded)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('云端记录 · 点击下载',
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!book.isDownloaded)
                const Icon(Icons.cloud_download_outlined, color: Colors.grey),
              _buildBookActionMenu(book),
            ],
          ),
          onTap: () => _openOrDownloadBook(book),
        );
      },
    );
  }
}
