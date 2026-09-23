// Package storage 抽象书库的底层存储，屏蔽本地文件系统与 WebDAV 的差异。
// 所有方法都以“逻辑相对路径”为入参，例如 /科幻/三体.epub、/__uploads__/x.epub、/.trashBin/y.epub，
// 各后端各自负责把逻辑路径映射到真实的物理路径或远端路径。
package storage

import (
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// FileInfo 是与具体后端无关的文件/目录元数据。
type FileInfo struct {
	Name    string
	Path    string // 逻辑相对路径（含 __uploads__ / .trashBin 前缀）
	IsDir   bool
	Size    int64
	ModTime time.Time
}

// WalkFunc 供 Walk 回调，返回 ErrSkipSubtree 可跳过当前目录整棵子树。
type WalkFunc func(info FileInfo) error

// ErrSkipSubtree 在 WalkFunc 中返回以跳过当前目录的子树遍历。
var ErrSkipSubtree = os.ErrInvalid

// Backend 是书库存储的统一接口。除 Open 外的方法均只涉及元数据，不下载文件内容。
type Backend interface {
	// ReadDir 只列出目标目录的直接子项（非递归），返回项的 Path 为逻辑相对路径。
	ReadDir(relPath string) ([]FileInfo, error)
	// Stat 读取单个文件/目录的元数据。
	Stat(relPath string) (FileInfo, error)
	// Exists 判断路径是否存在。
	Exists(relPath string) (bool, error)
	// Open 打开文件内容用于下载。返回值可能实现 io.ReadSeeker（本地）以支持 Range。
	Open(relPath string) (io.ReadCloser, FileInfo, error)
	// Create 写入文件内容（上传）。若父目录不存在需自动创建。
	Create(relPath string, r io.Reader) error
	// Rename 移动/重命名，用于垃圾箱移入与恢复。
	Rename(oldRel, newRel string) error
	// Remove 删除文件或空目录。
	Remove(relPath string) error
	// MkdirAll 递归创建目录。
	MkdirAll(relPath string) error
	// Walk 递归遍历子树（含目录与文件），仅回调元数据。
	Walk(relRoot string, fn WalkFunc) error
	// Fingerprint 计算书籍的稳定唯一指纹（book_id）。
	Fingerprint(relPath string, size int64) string
}

// Preheater 由需要启动预热的后端（如 WebDAV）可选实现，main 在启动时检测并触发。
type Preheater interface {
	// Preheat 在服务启动时全量缓存书库目录结构（仅路径与文件信息，不下载书籍）。
	Preheat() error
}

var (
	current Backend
	initMu  sync.Mutex
)

// Init 根据环境变量选择并初始化存储后端，由 main 在启动时调用。
// STORAGE_BACKEND=local（默认）使用本地文件系统；=webdav 使用 WebDAV。
func Init() error {
	initMu.Lock()
	defer initMu.Unlock()

	kind := strings.ToLower(strings.TrimSpace(os.Getenv("STORAGE_BACKEND")))
	switch kind {
	case "", "local":
		current = newLocalBackend()
		log.Println("存储后端：本地文件系统")
		return nil
	case "webdav":
		b, err := newWebdavBackend()
		if err != nil {
			return err
		}
		current = b
		log.Println("存储后端：WebDAV")
		return nil
	default:
		log.Printf("未知 STORAGE_BACKEND=%q，回退到本地文件系统", kind)
		current = newLocalBackend()
		return nil
	}
}

// Get 返回当前存储后端；若尚未初始化（如单元测试直接调用 handler），惰性回退为本地后端。
func Get() Backend {
	initMu.Lock()
	defer initMu.Unlock()
	if current == nil {
		current = newLocalBackend()
	}
	return current
}
