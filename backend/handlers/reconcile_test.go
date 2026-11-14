// handlers/reconcile_test.go
package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reader-sync/config"
	"reader-sync/models"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// setupReconcileTestDB 用内存 SQLite 替换全局 DB，迁移对账所需的全部表，测试结束后还原
func setupReconcileTestDB(t *testing.T) {
	t.Helper()

	db, err := gorm.Open(sqlite.Open("file::memory:"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.ReadingProgress{}, &models.Bookmark{}, &models.Favorite{}, &models.LibraryFileIndex{}); err != nil {
		t.Fatalf("迁移表结构失败: %v", err)
	}

	original := config.DB
	config.DB = db
	t.Cleanup(func() {
		config.DB = original
	})
}

func TestMatchCandidates(t *testing.T) {
	indexRows := []models.LibraryFileIndex{
		{BookID: "aaaa", Name: "三体.epub", Path: "/科幻/三体.epub", Extension: "epub"},
		{BookID: "bbbb", Name: "我的同年1-120.txt", Path: "/现代/我的同年1-120.txt", Extension: "txt"},
		{BookID: "dddd", Name: "沙丘.pdf", Path: "/科幻/沙丘.pdf", Extension: "pdf"},
	}

	// 唯一候选：归一化后只有“我的同年1-120”与“我的同年1-99”匹配
	unique, candidates := matchCandidates("我的同年1-99.txt", indexRows)
	if unique == nil || unique.BookID != "bbbb" {
		t.Fatalf("期望唯一候选 bbbb，得到 %+v (candidates=%v)", unique, candidates)
	}

	// 多候选：系列书“我的同年2”归一化后同样叫“我的同年”，撞名时 unique 为 nil 并列出全部候选
	withSeries := append(indexRows, models.LibraryFileIndex{
		BookID: "cccc", Name: "我的同年2.txt", Path: "/现代/我的同年2.txt", Extension: "txt",
	})
	unique, candidates = matchCandidates("我的同年1.txt", withSeries)
	if unique != nil {
		t.Fatalf("多候选时 unique 应为 nil，得到 %+v", unique)
	}
	if len(candidates) != 2 {
		t.Fatalf("期望 2 个候选，得到 %d: %+v", len(candidates), candidates)
	}

	// 无候选
	unique, candidates = matchCandidates("不存在的书.txt", indexRows)
	if unique != nil || len(candidates) != 0 {
		t.Fatalf("期望无候选，得到 unique=%+v candidates=%v", unique, candidates)
	}
}

// injectIndexRows 把索引快照注入内存状态，绕开测试环境不可用的真实文件系统遍历
func injectIndexRows(t *testing.T, rows []models.LibraryFileIndex) {
	t.Helper()
	libraryIndex.mu.Lock()
	libraryIndex.rows = rows
	libraryIndex.ready = true
	libraryIndex.refreshedAt = time.Now()
	libraryIndex.mu.Unlock()
	t.Cleanup(func() {
		libraryIndex.mu.Lock()
		libraryIndex.ready = false
		libraryIndex.rows = nil
		libraryIndex.mu.Unlock()
	})
}

func TestTryMigrateMovesAllRecords(t *testing.T) {
	setupReconcileTestDB(t)

	oldID, newID := "0000000000000000000000000000000000000000000000000000000000000099", "0000000000000000000000000000000000000000000000000000000000000120"
	userID := "u1"

	config.DB.Create(&models.ReadingProgress{
		ID: "p1", UserID: userID, BookID: oldID, Title: "我的同年1-99",
		FilePath: "/现代/我的同年1-99.txt", Progress: 0.5, Locator: "12345",
		ClientUpdatedAt: 1000,
	})
	config.DB.Create(&models.Bookmark{
		ID: "bm1", UserID: userID, BookID: oldID, Title: "书签", CreatedAt: 1, UpdatedAt: 1,
	})
	config.DB.Create(&models.Favorite{
		UserID: userID, BookID: oldID, Title: "我的同年1-99",
		FileName: "我的同年1-99.txt", RemotePath: "/现代/我的同年1-99.txt", AddedAt: 1, ClientUpdatedAt: 1,
	})
	// 另一个用户的同名旧记录不应被影响
	config.DB.Create(&models.ReadingProgress{
		ID: "p2", UserID: "u2", BookID: oldID, Title: "我的同年1-99",
		FilePath: "/现代/我的同年1-99.txt", Progress: 0.1, ClientUpdatedAt: 1000,
	})

	migrated, err := tryMigrate(userID, oldID, newID, "/现代/我的同年1-120.txt", "我的同年1-120")
	if err != nil || !migrated {
		t.Fatalf("迁移失败: migrated=%v err=%v", migrated, err)
	}

	var progress models.ReadingProgress
	if err := config.DB.Where("user_id = ?", userID).First(&progress).Error; err != nil {
		t.Fatalf("查询迁移后进度失败: %v", err)
	}
	if progress.BookID != newID || progress.FilePath != "/现代/我的同年1-120.txt" || progress.Locator != "12345" {
		t.Fatalf("进度迁移结果不符: %+v", progress)
	}
	if progress.ClientUpdatedAt <= 1000 {
		t.Fatalf("迁移后 client_updated_at 应上调以保证前端 LWW 合并: %d", progress.ClientUpdatedAt)
	}

	var bookmarks []models.Bookmark
	config.DB.Where("user_id = ?", userID).Find(&bookmarks)
	if len(bookmarks) != 1 || bookmarks[0].BookID != newID {
		t.Fatalf("书签迁移结果不符: %+v", bookmarks)
	}

	var favorite models.Favorite
	if err := config.DB.Where("user_id = ?", userID).First(&favorite).Error; err != nil {
		t.Fatalf("查询迁移后收藏失败: %v", err)
	}
	if favorite.BookID != newID || favorite.FileName != "我的同年1-120.txt" || favorite.RemotePath != "/现代/我的同年1-120.txt" {
		t.Fatalf("收藏迁移结果不符: %+v", favorite)
	}

	// 其他用户记录不受影响
	var otherCount int64
	config.DB.Model(&models.ReadingProgress{}).Where("user_id = ?", "u2").Count(&otherCount)
	if otherCount != 1 {
		t.Fatalf("其他用户记录不应被迁移: %d", otherCount)
	}
}

func TestTryMigrateSkipsWhenNewRecordExists(t *testing.T) {
	setupReconcileTestDB(t)

	oldID, newID := "aaa9", "aaa9-new"
	oldID = "0000000000000000000000000000000000000000000000000000000000000099"
	newID = "0000000000000000000000000000000000000000000000000000000000000120"
	userID := "u1"

	config.DB.Create(&models.ReadingProgress{
		ID: "p-old", UserID: userID, BookID: oldID, Title: "旧", ClientUpdatedAt: 1000,
	})
	config.DB.Create(&models.ReadingProgress{
		ID: "p-new", UserID: userID, BookID: newID, Title: "新", ClientUpdatedAt: 2000,
	})

	migrated, err := tryMigrate(userID, oldID, newID, "/x.txt", "x")
	if err != nil {
		t.Fatalf("不应返回错误: %v", err)
	}
	if migrated {
		t.Fatal("新 book_id 已有记录时应放弃迁移")
	}

	// 旧记录保持原样
	var oldProgress models.ReadingProgress
	config.DB.Where("id = ?", "p-old").First(&oldProgress)
	if oldProgress.BookID != oldID {
		t.Fatalf("旧记录不应被改动: %+v", oldProgress)
	}
}

func doReconcile(t *testing.T, userID, uri, body string) (int, map[string]interface{}) {
	t.Helper()

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", userID)
	c.Request = httptest.NewRequest(http.MethodPost, uri, bytes.NewBufferString(body))
	c.Request.Header.Set("Content-Type", "application/json")

	if uri == "/api/v1/sync/reconcile/confirm" {
		ConfirmReconcile(c)
	} else {
		ReconcileProgress(c)
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应失败: %v body=%s", err, w.Body.String())
	}
	return w.Code, resp
}

func TestConfirmReconcileValidatesLibrary(t *testing.T) {
	setupReconcileTestDB(t)

	oldID := "0000000000000000000000000000000000000000000000000000000000000099"
	newID := "0000000000000000000000000000000000000000000000000000000000000120"
	unknownID := "0000000000000000000000000000000000000000000000000000000000000ff1"
	userID := "u1"

	config.DB.Create(&models.ReadingProgress{
		ID: "p1", UserID: userID, BookID: oldID, Title: "我的同年1-99",
		FilePath: "/现代/我的同年1-99.txt", Progress: 0.5, ClientUpdatedAt: 1000,
	})
	config.DB.Create(&models.LibraryFileIndex{
		Path: "/现代/我的同年1-120.txt", BookID: newID, Name: "我的同年1-120.txt",
		Extension: "txt", Size: 100, ModTime: time.Now().UnixMilli(),
	})
	injectIndexRows(t, []models.LibraryFileIndex{
		{Path: "/现代/我的同年1-120.txt", BookID: newID, Name: "我的同年1-120.txt", Extension: "txt"},
	})

	// 目标不在库内：拒绝
	code, _ := doReconcile(t, userID, "/api/v1/sync/reconcile/confirm",
		`{"old_book_id":"`+oldID+`","new_book_id":"`+unknownID+`"}`)
	if code != http.StatusNotFound {
		t.Fatalf("目标不在库内应 404，得到 %d", code)
	}

	// 索引里没有旧 book_id（旧记录是孤儿）：允许迁移
	code, resp := doReconcile(t, userID, "/api/v1/sync/reconcile/confirm",
		`{"old_book_id":"`+oldID+`","new_book_id":"`+newID+`"}`)
	if code != http.StatusOK {
		t.Fatalf("确认迁移应成功，得到 %d: %v", code, resp)
	}

	var progress models.ReadingProgress
	config.DB.Where("user_id = ?", userID).First(&progress)
	if progress.BookID != newID {
		t.Fatalf("确认迁移未生效: %+v", progress)
	}
}
