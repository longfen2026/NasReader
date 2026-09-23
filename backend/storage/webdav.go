package storage

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path"
	"reader-sync/utils"
	"strings"
	"sync"
	"time"

	"github.com/studio-b12/gowebdav"
)

// webdavBackend 用 WebDAV 远端实现 Backend，并对目录元数据做内存缓存。
// 逻辑路径（含 __uploads__ / .trashBin 前缀）映射到远端两个根：书库根与上传根。
type webdavBackend struct {
	client      *gowebdav.Client
	booksRoot   string // 远端书库根，如 /books
	uploadsRoot string // 远端上传根，如 /uploads

	mu    sync.RWMutex
	cache map[string][]FileInfo // key = 逻辑目录相对路径，value = 该目录直接子项
}

func newWebdavBackend() (*webdavBackend, error) {
	url := strings.TrimSpace(os.Getenv("WEBDAV_URL"))
	if url == "" {
		return nil, errors.New("STORAGE_BACKEND=webdav 时必须设置 WEBDAV_URL")
	}
	user := os.Getenv("WEBDAV_USER")
	pass := os.Getenv("WEBDAV_PASSWORD")

	booksRoot := normalizeRemoteRoot(os.Getenv("WEBDAV_BOOKS_PATH"), "/books")
	uploadsRoot := normalizeRemoteRoot(os.Getenv("WEBDAV_UPLOADS_PATH"), "/uploads")

	client := gowebdav.NewClient(url, user, pass)
	client.SetTimeout(30 * time.Second)

	// gowebdav 默认使用 NewAutoAuth，依赖服务端在响应里返回 Www-Authenticate 挑战头
	// 才能协商出 Basic/Digest。但 Connect() 用 OPTIONS 探测，很多 WebDAV 服务器
	// （nginx dav、Apache mod_dav、Synology 等）对 OPTIONS 不返回挑战头，或本就要求
	// 抢占式 Basic 认证，导致协商失败并直接返回 401。
	// 这里在提供了凭据时预先带上 Authorization 头，覆盖最常见的 Basic 认证场景。
	if user != "" {
		token := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
		client.SetHeader("Authorization", "Basic "+token)
	} else {
		log.Printf("WebDAV 警告: 未设置 WEBDAV_USER，将以匿名方式连接，若服务器需要认证会返回 401")
	}

	if err := client.Connect(); err != nil {
		return nil, fmt.Errorf("连接 WebDAV 失败（请核对 WEBDAV_URL/WEBDAV_USER/WEBDAV_PASSWORD，并确认服务器支持 Basic 认证）: %w", err)
	}

	b := &webdavBackend{
		client:      client,
		booksRoot:   booksRoot,
		uploadsRoot: uploadsRoot,
		cache:       make(map[string][]FileInfo),
	}
	return b, nil
}

// Preheat 启动时全量预热：递归拉取书库与上传目录的元数据（不下载文件内容）。
func (b *webdavBackend) Preheat() error {
	if err := b.warmSubtree("/"); err != nil {
		log.Printf("WebDAV 书库全量缓存失败（不影响启动，将按需刷新）: %v", err)
	}
	if err := b.warmSubtree("/" + utils.UploadsPathPrefix); err != nil {
		log.Printf("WebDAV 上传目录全量缓存失败: %v", err)
	}
	b.mu.RLock()
	log.Printf("WebDAV 全量缓存完成，共缓存 %d 个目录", len(b.cache))
	b.mu.RUnlock()
	return nil
}

// warmSubtree 以 BFS 逐层 PROPFIND(Depth:1) 递归预热，避免依赖服务端 Depth:infinity 支持。
func (b *webdavBackend) warmSubtree(logicalDir string) error {
	queue := []string{utils.NormalizeRelPath(logicalDir)}
	for len(queue) > 0 {
		dir := queue[0]
		queue = queue[1:]

		items, err := b.readDirRemote(dir)
		if err != nil {
			// 上传目录可能尚未在远端创建，忽略 404
			if gowebdav.IsErrNotFound(err) {
				continue
			}
			return err
		}
		b.storeCache(dir, items)
		for _, it := range items {
			if it.IsDir {
				queue = append(queue, it.Path)
			}
		}
	}
	return nil
}

// remotePath 把逻辑相对路径映射为远端绝对路径。
func (b *webdavBackend) remotePath(relPath string) string {
	norm := utils.NormalizeRelPath(relPath)
	if utils.IsUploadsPath(norm) {
		sub := strings.TrimPrefix(norm, "/"+utils.UploadsPathPrefix)
		return joinRemote(b.uploadsRoot, sub)
	}
	return joinRemote(b.booksRoot, norm)
}

// readDirRemote 直接向远端发起单层 PROPFIND，转换为与后端无关的 FileInfo（Path 为逻辑路径）。
func (b *webdavBackend) readDirRemote(logicalDir string) ([]FileInfo, error) {
	remote := b.remotePath(logicalDir)
	infos, err := b.client.ReadDir(remote)
	if err != nil {
		return nil, err
	}
	base := utils.NormalizeRelPath(logicalDir)
	out := make([]FileInfo, 0, len(infos))
	for _, fi := range infos {
		out = append(out, FileInfo{
			Name:    fi.Name(),
			Path:    joinLogical(base, fi.Name()),
			IsDir:   fi.IsDir(),
			Size:    fi.Size(),
			ModTime: fi.ModTime(),
		})
	}
	return out, nil
}

func (b *webdavBackend) storeCache(logicalDir string, items []FileInfo) {
	key := utils.NormalizeRelPath(logicalDir)
	b.mu.Lock()
	b.cache[key] = items
	b.mu.Unlock()
}

func (b *webdavBackend) invalidate(logicalDir string) {
	key := utils.NormalizeRelPath(logicalDir)
	b.mu.Lock()
	delete(b.cache, key)
	b.mu.Unlock()
}

func (b *webdavBackend) cachedDir(logicalDir string) ([]FileInfo, bool) {
	key := utils.NormalizeRelPath(logicalDir)
	b.mu.RLock()
	items, ok := b.cache[key]
	b.mu.RUnlock()
	return items, ok
}

// ReadDir 只读当前目录：向远端刷新单层并更新缓存（满足“打开目录才刷新对应目录”）。
func (b *webdavBackend) ReadDir(relPath string) ([]FileInfo, error) {
	items, err := b.readDirRemote(relPath)
	if err != nil {
		// 刷新失败时回退到缓存，保证弱网下仍可浏览
		if cached, ok := b.cachedDir(relPath); ok {
			return cached, nil
		}
		return nil, err
	}
	b.storeCache(relPath, items)
	return items, nil
}

// Stat 优先命中父目录缓存，未命中再走远端。
func (b *webdavBackend) Stat(relPath string) (FileInfo, error) {
	norm := utils.NormalizeRelPath(relPath)
	if norm != "/" {
		parent := path.Dir(norm)
		if items, ok := b.cachedDir(parent); ok {
			for _, it := range items {
				if it.Path == norm {
					return it, nil
				}
			}
		}
	}
	fi, err := b.client.Stat(b.remotePath(norm))
	if err != nil {
		return FileInfo{}, err
	}
	return FileInfo{
		Name:    fi.Name(),
		Path:    norm,
		IsDir:   fi.IsDir(),
		Size:    fi.Size(),
		ModTime: fi.ModTime(),
	}, nil
}

func (b *webdavBackend) Exists(relPath string) (bool, error) {
	if _, err := b.client.Stat(b.remotePath(relPath)); err != nil {
		if gowebdav.IsErrNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (b *webdavBackend) Open(relPath string) (io.ReadCloser, FileInfo, error) {
	info, err := b.Stat(relPath)
	if err != nil {
		return nil, FileInfo{}, err
	}
	rc, err := b.client.ReadStream(b.remotePath(relPath))
	if err != nil {
		return nil, FileInfo{}, err
	}
	return rc, info, nil
}

func (b *webdavBackend) Create(relPath string, r io.Reader) error {
	norm := utils.NormalizeRelPath(relPath)
	remote := b.remotePath(norm)
	if dir := path.Dir(remote); dir != "." && dir != "/" {
		_ = b.client.MkdirAll(dir, 0o755)
	}
	if err := b.client.WriteStream(remote, r, 0o644); err != nil {
		return err
	}
	b.invalidate(path.Dir(norm))
	return nil
}

func (b *webdavBackend) Rename(oldRel, newRel string) error {
	oldNorm := utils.NormalizeRelPath(oldRel)
	newNorm := utils.NormalizeRelPath(newRel)
	dstRemote := b.remotePath(newNorm)
	if dir := path.Dir(dstRemote); dir != "." && dir != "/" {
		_ = b.client.MkdirAll(dir, 0o755)
	}
	if err := b.client.Rename(b.remotePath(oldNorm), dstRemote, true); err != nil {
		return err
	}
	b.invalidate(path.Dir(oldNorm))
	b.invalidate(path.Dir(newNorm))
	return nil
}

func (b *webdavBackend) Remove(relPath string) error {
	norm := utils.NormalizeRelPath(relPath)
	if err := b.client.Remove(b.remotePath(norm)); err != nil {
		return err
	}
	b.invalidate(path.Dir(norm))
	b.invalidate(norm)
	return nil
}

func (b *webdavBackend) MkdirAll(relPath string) error {
	norm := utils.NormalizeRelPath(relPath)
	if err := b.client.MkdirAll(b.remotePath(norm), 0o755); err != nil {
		return err
	}
	b.invalidate(path.Dir(norm))
	return nil
}

// Walk 基于缓存做递归遍历（不打网络），供搜索使用；缓存缺失的子树自动跳过。
func (b *webdavBackend) Walk(relRoot string, fn WalkFunc) error {
	root := utils.NormalizeRelPath(relRoot)
	return b.walkCached(root, fn)
}

func (b *webdavBackend) walkCached(dir string, fn WalkFunc) error {
	items, ok := b.cachedDir(dir)
	if !ok {
		return nil
	}
	for _, it := range items {
		err := fn(it)
		if err == ErrSkipSubtree {
			continue
		}
		if err != nil {
			return err
		}
		if it.IsDir {
			if subErr := b.walkCached(it.Path, fn); subErr != nil {
				return subErr
			}
		}
	}
	return nil
}

func (b *webdavBackend) Fingerprint(relPath string, size int64) string {
	return pathSizeFingerprint(utils.NormalizeRelPath(relPath), size)
}

// normalizeRemoteRoot 归一化远端根路径：确保以 / 开头、去除尾部 /，空值用默认。
func normalizeRemoteRoot(raw, def string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		raw = def
	}
	raw = "/" + strings.Trim(raw, "/")
	return raw
}

// joinRemote 把远端根与逻辑子路径拼成远端绝对路径。
func joinRemote(root, sub string) string {
	sub = strings.TrimPrefix(utils.NormalizeRelPath(sub), "/")
	if sub == "" {
		return root
	}
	return strings.TrimRight(root, "/") + "/" + sub
}
