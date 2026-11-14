// handlers/reconcile.go
package handlers

import (
	"errors"
	"log"
	"net/http"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"reader-sync/config"
	"reader-sync/models"
	"reader-sync/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// fingerprintRe 只把“像内容指纹”的 book_id 视为可对账的孤儿；
// 旧版本以文件名作为 book_id 的历史记录不参与（由前端 migrateLegacyBookId 处理）。
var fingerprintRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ReconcileCandidate 对账候选：库内一个可能的“新书”文件
type ReconcileCandidate struct {
	BookID    string `json:"book_id"`
	Name      string `json:"name"`
	Path      string `json:"path"`
	Extension string `json:"extension"`
}

// ReconcilePending 匹配到多个候选、需用户确认的孤儿记录
type ReconcilePending struct {
	OldBookID  string               `json:"old_book_id"`
	Title      string               `json:"title"`
	OldFilePath string              `json:"old_file_path"`
	Candidates []ReconcileCandidate `json:"candidates"`
}

// ReconcileMigration 已自动完成的迁移
type ReconcileMigration struct {
	OldBookID  string `json:"old_book_id"`
	NewBookID  string `json:"new_book_id"`
	NewFilePath string `json:"new_file_path"`
	Title      string `json:"title"`
}

// ReconcileProgress 对账入口（打开书架时由前端调用）：
// 找出该用户指纹已不在书库中的孤儿记录，按归一化书名匹配新文件，
// 唯一候选自动迁移，多个候选返回 pending 交由用户确认。
func ReconcileProgress(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	// 索引未就绪（如服务刚启动、后台预构建未完成）时让前端静默跳过，下次书架加载再试
	indexRows, err := ensureIndexReady()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"status": "index_not_ready"})
		return
	}

	orphans := findOrphanBookIDs(userID, indexRows)
	if len(orphans) == 0 {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "migrated": []ReconcileMigration{}, "pending": []ReconcilePending{}})
		return
	}

	migrated := make([]ReconcileMigration, 0, len(orphans))
	pending := make([]ReconcilePending, 0)

	for oldID, origin := range orphans {
		// 旧文件名优先取远端路径基名（含扩展名更完整），退化为标题
		oldName := filepath.Base(origin.filePath)
		if oldName == "/" || oldName == "." || oldName == "\\" || oldName == "" {
			oldName = origin.title
		}
		unique, candidates := matchCandidates(oldName, indexRows)

		if len(candidates) > 1 {
			// 多个候选：无法确定对应关系，交给用户确认
			sortCandidates(candidates)
			pending = append(pending, ReconcilePending{
				OldBookID:   oldID,
				Title:       origin.title,
				OldFilePath: origin.filePath,
				Candidates:  candidates,
			})
			continue
		}
		if unique == nil {
			continue // 无相似文件名，按需求暂不迁移
		}

		target := unique
		result, err := tryMigrate(userID, oldID, target.BookID, target.Path, titleFromFileName(target.Name))
		if err != nil {
			log.Printf("对账迁移失败 user=%s old=%s new=%s: %v", userID, oldID, target.BookID, err)
			continue
		}
		if result {
			migrated = append(migrated, ReconcileMigration{
				OldBookID:   oldID,
				NewBookID:   target.BookID,
				NewFilePath: target.Path,
				Title:       titleFromFileName(target.Name),
			})
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"status":   "ok",
		"migrated": migrated,
		"pending":  pending,
	})
}

// ConfirmReconcileRequest 用户在歧义弹窗中确认后的迁移请求
type ConfirmReconcileRequest struct {
	OldBookID string `json:"old_book_id" binding:"required"`
	NewBookID string `json:"new_book_id" binding:"required"`
}

// ConfirmReconcile 执行用户确认的迁移：旧记录仍为孤儿且新文件仍在库内才允许
func ConfirmReconcile(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req ConfirmReconcileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	indexRows, err := ensureIndexReady()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"status": "index_not_ready"})
		return
	}

	// 新 book_id 必须仍在库内
	var target *models.LibraryFileIndex
	for i := range indexRows {
		if indexRows[i].BookID == req.NewBookID {
			target = &indexRows[i]
			break
		}
	}
	if target == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "目标书籍已不在书库中，无法迁移"})
		return
	}

	// 旧 book_id 必须仍是孤儿（避免把有效记录错误改挂到别的文件上）
	orphans := findOrphanBookIDs(userID, indexRows)
	if _, ok := orphans[req.OldBookID]; !ok {
		c.JSON(http.StatusConflict, gin.H{"error": "旧记录已不是孤儿记录，无需迁移"})
		return
	}

	title := titleFromFileName(target.Name)
	result, err := tryMigrate(userID, req.OldBookID, req.NewBookID, target.Path, title)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "迁移失败: " + err.Error()})
		return
	}
	if !result {
		c.JSON(http.StatusConflict, gin.H{"error": "新书籍已存在阅读记录，无需迁移"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"status": "ok",
		"migration": ReconcileMigration{
			OldBookID:   req.OldBookID,
			NewBookID:   req.NewBookID,
			NewFilePath: target.Path,
			Title:       title,
		},
	})
}

// orphanOrigin 孤儿记录的名称来源信息
type orphanOrigin struct {
	title    string
	filePath string
}

// findOrphanBookIDs 找出该用户所有“内容指纹已不在当前书库中”的 book_id，
// 并记录其名称来源（优先进度记录的 Title/FilePath，其次收藏的 FileName/RemotePath）。
// 纯书签孤儿（无进度、无收藏）拿不到名称，无法匹配，直接跳过。
func findOrphanBookIDs(userID string, indexRows []models.LibraryFileIndex) map[string]orphanOrigin {
	inLibrary := make(map[string]bool, len(indexRows))
	for _, row := range indexRows {
		inLibrary[row.BookID] = true
	}

	orphans := make(map[string]orphanOrigin)

	var progresses []models.ReadingProgress
	if err := config.DB.Where("user_id = ?", userID).Find(&progresses).Error; err != nil {
		log.Printf("对账查询进度记录失败: %v", err)
		return orphans
	}
	for _, p := range progresses {
		if fingerprintRe.MatchString(p.BookID) && !inLibrary[p.BookID] {
			orphans[p.BookID] = orphanOrigin{title: p.Title, filePath: p.FilePath}
		}
	}

	// 收藏可补齐“只有收藏、进度已被删”的孤儿名称，并顺带把收藏也纳入迁移范围
	var favorites []models.Favorite
	if err := config.DB.Where("user_id = ? AND is_deleted = ?", userID, false).Find(&favorites).Error; err != nil {
		log.Printf("对账查询收藏记录失败: %v", err)
		return orphans
	}
	for _, f := range favorites {
		if !fingerprintRe.MatchString(f.BookID) || inLibrary[f.BookID] {
			continue
		}
		if origin, ok := orphans[f.BookID]; ok {
			// 进度记录缺名称时用收藏的冗余字段兜底
			if origin.title == "" && origin.filePath == "" {
				origin.title = f.Title
				origin.filePath = f.RemotePath
				orphans[f.BookID] = origin
			}
		} else {
			orphans[f.BookID] = orphanOrigin{title: f.Title, filePath: f.RemotePath}
		}
	}

	// 名称来源全空的孤儿无法匹配，剔除
	for id, origin := range orphans {
		if origin.title == "" && origin.filePath == "" {
			delete(orphans, id)
		}
	}
	return orphans
}

// tryMigrate 执行一次迁移事务；返回 false 表示新 book_id 下已有该用户记录（无需迁移）。
func tryMigrate(userID, oldBookID, newBookID, newFilePath, newTitle string) (bool, error) {
	if oldBookID == newBookID {
		return false, nil
	}

	err := config.DB.Transaction(func(tx *gorm.DB) error {
		// 新 book_id 下已有任何进度记录时放弃迁移，避免覆盖真实的新阅读数据
		var count int64
		if err := tx.Model(&models.ReadingProgress{}).
			Where("user_id = ? AND book_id = ?", userID, newBookID).
			Count(&count).Error; err != nil {
			return err
		}
		if count > 0 {
			return errNewRecordExists
		}
		return migrateBookRecordsInTx(tx, userID, oldBookID, newBookID, newFilePath, newTitle)
	})

	if err == errNewRecordExists {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	log.Printf("已完成阅读记录迁移: user=%s %s -> %s (%s)", userID, oldBookID, newBookID, newFilePath)
	return true, nil
}

// errNewRecordExists 新 book_id 下已存在记录，放弃迁移的内部哨兵错误
var errNewRecordExists = errors.New("new book record already exists")

// titleFromFileName 由文件名推导书名展示标题（去扩展名）
func titleFromFileName(name string) string {
	base := filepath.Base(name)
	title := strings.TrimSuffix(base, filepath.Ext(base))
	if strings.TrimSpace(title) == "" {
		return base
	}
	return title
}

// matchCandidates 按归一化书名在库内索引中找旧文件的可能新版本。
// 返回：唯一候选（多于一个时为 nil）与全部候选列表。
func matchCandidates(oldName string, indexRows []models.LibraryFileIndex) (*models.LibraryFileIndex, []ReconcileCandidate) {
	key := utils.NormalizeBookName(oldName)
	if key == "" {
		return nil, nil
	}

	var matched []models.LibraryFileIndex
	for _, row := range indexRows {
		if utils.NormalizeBookName(row.Name) == key {
			matched = append(matched, row)
		}
	}
	if len(matched) == 0 {
		return nil, nil
	}

	candidates := make([]ReconcileCandidate, 0, len(matched))
	for _, row := range matched {
		candidates = append(candidates, ReconcileCandidate{
			BookID:    row.BookID,
			Name:      row.Name,
			Path:      row.Path,
			Extension: row.Extension,
		})
	}

	if len(matched) == 1 {
		return &matched[0], candidates
	}
	return nil, candidates
}

// sortCandidates 按路径排序候选，保证 pending 列表顺序稳定（便于前端忽略记忆的签名比对）
func sortCandidates(candidates []ReconcileCandidate) {
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].Path < candidates[j].Path
	})
}
