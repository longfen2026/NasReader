// handlers/library_index.go
package handlers

import (
	"errors"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"reader-sync/config"
	"reader-sync/models"
	"reader-sync/storage"
	"reader-sync/utils"

	"gorm.io/gorm"
)

// errIndexNotReady 索引尚未构建完成（或本次构建失败）时的哨兵错误
var errIndexNotReady = errors.New("library index not ready")

// libraryIndex 全库文件索引的内存快照与构建状态。
// Walk 本身只读元数据（便宜），昂贵的 Fingerprint（读文件头尾各 4KB）
// 借助 SQLite 持久化的 LibraryFileIndex 表按 Size+ModTime 增量复用。
type libraryIndexState struct {
	mu          sync.Mutex
	rows        []models.LibraryFileIndex // 最近一次构建的索引快照（已按 book_id 去重）
	ready       bool                      // 至少完整构建过一次
	building    bool
	refreshedAt time.Time // 最近一次完整重建时间，新鲜度窗口内直接复用快照
}

// indexRefreshInterval 索引快照的新鲜度窗口：窗口内对账直接复用快照，
// 避免每次进书架都重走全库；窗口过后下次对账会重新遍历以感知新增/删除。
const indexRefreshInterval = 30 * time.Second

var libraryIndex libraryIndexState

// StartLibraryIndexBuild 服务启动时后台预构建全库索引（照 AuthLimiter.StartCleanup 的常驻 goroutine 模式），
// 首次请求无需在 HTTP 上下文里等完整库扫描。
func StartLibraryIndexBuild() {
	go func() {
		if _, err := RefreshLibraryIndex(); err != nil {
			log.Printf("后台构建全库文件索引失败: %v", err)
		}
	}()
}

// RefreshLibraryIndex 重新遍历书库并增量刷新索引，返回按 book_id 去重后的索引快照。
// 并发调用时仅第一个执行扫描，其余等待后直接复用结果。
func RefreshLibraryIndex() ([]models.LibraryFileIndex, error) {
	libraryIndex.mu.Lock()
	if libraryIndex.building {
		libraryIndex.mu.Unlock()
		waitForIndexBuild()
		libraryIndex.mu.Lock()
		defer libraryIndex.mu.Unlock()
		if libraryIndex.ready {
			return libraryIndex.rows, nil
		}
		return nil, errIndexNotReady
	}
	libraryIndex.building = true
	libraryIndex.mu.Unlock()

	defer func() {
		libraryIndex.mu.Lock()
		libraryIndex.building = false
		libraryIndex.mu.Unlock()
	}()

	rows, err := buildLibraryIndex()
	if err != nil {
		return nil, err
	}

	libraryIndex.mu.Lock()
	libraryIndex.rows = rows
	libraryIndex.ready = true
	libraryIndex.refreshedAt = time.Now()
	libraryIndex.mu.Unlock()
	return rows, nil
}

// waitForIndexBuild 轮询等待进行中的构建结束（最长约 5 分钟，超时放弃）
func waitForIndexBuild() {
	for i := 0; i < 600; i++ {
		time.Sleep(500 * time.Millisecond)
		libraryIndex.mu.Lock()
		building := libraryIndex.building
		libraryIndex.mu.Unlock()
		if !building {
			return
		}
	}
}

// buildLibraryIndex 遍历书库与上传目录两个逻辑根，增量刷新 LibraryFileIndex 表。
// 删除的文件随本次重建自然从表中消失；Size/ModTime 未变的文件复用已有指纹。
func buildLibraryIndex() ([]models.LibraryFileIndex, error) {
	if config.DB == nil {
		return nil, errIndexNotReady
	}

	var cached []models.LibraryFileIndex
	if err := config.DB.Find(&cached).Error; err != nil {
		return nil, err
	}
	byPath := make(map[string]models.LibraryFileIndex, len(cached))
	for _, row := range cached {
		byPath[row.Path] = row
	}

	backend := storage.Get()
	seen := make(map[string]bool)

	upsert := func(info storage.FileInfo) error {
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(info.Name), "."))
		if !IsSupportedBookExt(ext) {
			return nil
		}

		modMilli := info.ModTime.UnixMilli()
		if prev, ok := byPath[info.Path]; ok && prev.Size == info.Size && prev.ModTime == modMilli && prev.BookID != "" {
			// 未变化：复用已有指纹，避免重读文件头尾
			seen[info.Path] = true
			return nil
		}

		row := models.LibraryFileIndex{
			Path:      info.Path,
			BookID:    backend.Fingerprint(info.Path, info.Size),
			Name:      info.Name,
			Extension: ext,
			Size:      info.Size,
			ModTime:   modMilli,
		}
		if row.BookID == "" {
			// 文件此刻可能正被替换/删除导致读取失败，跳过即可，下轮再算
			return nil
		}
		if err := config.DB.Save(&row).Error; err != nil {
			log.Printf("写入文件索引失败 %s: %v", info.Path, err)
			return nil
		}
		seen[info.Path] = true
		return nil
	}

	walkRoot := func(root string) error {
		return backend.Walk(root, func(info storage.FileInfo) error {
			if info.IsDir {
				// 与搜索接口一致：隐藏目录（含垃圾箱 .trashBin）整棵子树跳过
				if info.Path != root && strings.HasPrefix(info.Name, ".") {
					return storage.ErrSkipSubtree
				}
				return nil
			}
			if strings.HasPrefix(info.Name, ".") {
				return nil
			}
			return upsert(info)
		})
	}

	if err := walkRoot("/"); err != nil {
		return nil, err
	}
	// 上传目录根不存在等情况不视为致命错误
	_ = walkRoot("/" + utils.UploadsPathPrefix)

	// 清理已消失文件对应的索引行
	for path := range byPath {
		if !seen[path] {
			if err := config.DB.Where("path = ?", path).Delete(&models.LibraryFileIndex{}).Error; err != nil {
				log.Printf("清理失效文件索引失败 %s: %v", path, err)
			}
		}
	}

	return dedupeIndexRowsByBookID(), nil
}

// dedupeIndexRowsByBookID 从数据库读取全部索引行并按 book_id 去重。
// 同一内容存在多份（不同路径同指纹）时只保留一个代表路径，避免对账时出现重复候选。
func dedupeIndexRowsByBookID() []models.LibraryFileIndex {
	var rows []models.LibraryFileIndex
	if err := config.DB.Find(&rows).Error; err != nil {
		return nil
	}
	seen := make(map[string]bool, len(rows))
	deduped := make([]models.LibraryFileIndex, 0, len(rows))
	for _, row := range rows {
		if seen[row.BookID] {
			continue
		}
		seen[row.BookID] = true
		deduped = append(deduped, row)
	}
	return deduped
}

// ensureIndexReady 返回索引快照：新鲜度窗口内直接复用，过期则重新遍历书库
// （保证新增/删除的文件能被对账感知）；索引从未成功构建时返回 errIndexNotReady。
func ensureIndexReady() ([]models.LibraryFileIndex, error) {
	libraryIndex.mu.Lock()
	ready := libraryIndex.ready
	fresh := time.Since(libraryIndex.refreshedAt) < indexRefreshInterval
	rows := libraryIndex.rows
	libraryIndex.mu.Unlock()
	if ready && fresh {
		return rows, nil
	}
	if !ready {
		return nil, errIndexNotReady
	}
	return RefreshLibraryIndex()
}

// migrateBookRecordsInTx 在一个事务里把该用户某本旧书的进度/书签/收藏迁移到新 book_id 上。
// filePath/title 非空时同步更新为新文件的展示信息。
func migrateBookRecordsInTx(tx *gorm.DB, userID, oldBookID, newBookID, newFilePath, newTitle string) error {
	if err := tx.Model(&models.ReadingProgress{}).
		Where("user_id = ? AND book_id = ?", userID, oldBookID).
		Updates(map[string]interface{}{
			"book_id":            newBookID,
			"file_path":          newFilePath,
			"title":              newTitle,
			"client_updated_at":  time.Now().UnixMilli(),
		}).Error; err != nil {
		return err
	}

	if err := tx.Model(&models.Bookmark{}).
		Where("user_id = ? AND book_id = ?", userID, oldBookID).
		Update("book_id", newBookID).Error; err != nil {
		return err
	}

	// 收藏：更新主键 book_id 并同步冗余的文件名与远端路径；墓碑（已取消收藏）不迁移
	favUpdates := map[string]interface{}{
		"book_id":    newBookID,
		"file_name":  filepath.Base(newFilePath),
		"remote_path": newFilePath,
	}
	if err := tx.Model(&models.Favorite{}).
		Where("user_id = ? AND book_id = ? AND is_deleted = ?", userID, oldBookID, false).
		Updates(favUpdates).Error; err != nil {
		return err
	}
	return nil
}
