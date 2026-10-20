package handlers

import (
	"bytes"
	"fmt"
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

func TestRemoveBookReadingDataPreservesFavoritesAndOtherUsers(t *testing.T) {
	db, err := gorm.Open(
		sqlite.Open(fmt.Sprintf("file:remove-reading-data-%d?mode=memory&cache=shared", time.Now().UnixNano())),
		&gorm.Config{Logger: logger.Default.LogMode(logger.Silent)},
	)
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(
		&models.ReadingProgress{},
		&models.Bookmark{},
		&models.Favorite{},
	); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}

	originalDB := config.DB
	config.DB = db
	t.Cleanup(func() {
		config.DB = originalDB
	})

	progress := []models.ReadingProgress{
		{ID: "progress-user-a", UserID: "user-a", BookID: "book-1", Locator: "0"},
		{ID: "progress-user-b", UserID: "user-b", BookID: "book-1", Locator: "0"},
	}
	if err := db.Create(&progress).Error; err != nil {
		t.Fatalf("创建测试进度失败: %v", err)
	}
	now := time.Now().UnixMilli()
	bookmarks := []models.Bookmark{
		{ID: "bookmark-user-a", UserID: "user-a", BookID: "book-1", Title: "书签 A", CreatedAt: now, UpdatedAt: now},
		{ID: "bookmark-user-b", UserID: "user-b", BookID: "book-1", Title: "书签 B", CreatedAt: now, UpdatedAt: now},
	}
	if err := db.Create(&bookmarks).Error; err != nil {
		t.Fatalf("创建测试书签失败: %v", err)
	}
	favorite := models.Favorite{
		UserID: "user-a", BookID: "book-1", Title: "收藏书籍",
	}
	if err := db.Create(&favorite).Error; err != nil {
		t.Fatalf("创建测试收藏失败: %v", err)
	}

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", "user-a")
	c.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/v1/sync/remove-reading-data",
		bytes.NewBufferString(`{"book_id":"book-1"}`),
	)
	c.Request.Header.Set("Content-Type", "application/json")

	RemoveBookReadingData(c)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %s", w.Code, w.Body.String())
	}

	var remainingProgress []models.ReadingProgress
	if err := db.Where("book_id = ?", "book-1").Find(&remainingProgress).Error; err != nil {
		t.Fatalf("查询剩余进度失败: %v", err)
	}
	if len(remainingProgress) != 1 || remainingProgress[0].UserID != "user-b" {
		t.Errorf("仅应保留其他用户的进度，实际 %+v", remainingProgress)
	}

	var remainingBookmarks []models.Bookmark
	if err := db.Where("book_id = ?", "book-1").Find(&remainingBookmarks).Error; err != nil {
		t.Fatalf("查询剩余书签失败: %v", err)
	}
	if len(remainingBookmarks) != 1 || remainingBookmarks[0].UserID != "user-b" {
		t.Errorf("仅应保留其他用户的书签，实际 %+v", remainingBookmarks)
	}

	var remainingFavorites []models.Favorite
	if err := db.Where("book_id = ?", "book-1").Find(&remainingFavorites).Error; err != nil {
		t.Fatalf("查询剩余收藏失败: %v", err)
	}
	if len(remainingFavorites) != 1 || remainingFavorites[0].UserID != "user-a" {
		t.Errorf("收藏应保留，实际 %+v", remainingFavorites)
	}
}
