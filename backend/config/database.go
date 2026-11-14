package config

import (
	"log"
	"os"
	"path/filepath"

	"github.com/glebarez/sqlite" // 纯 Go 实现的 SQLite 驱动，无 CGO 依赖
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"reader-sync/models"
)

var DB *gorm.DB

// InitDB 初始化 SQLite 数据库连接并自动迁移数据表
func InitDB() {
	dbDir := "data"
	dbFile := filepath.Join(dbDir, "reader.db")

	// 1. 确保数据持久化目录存在
	if err := os.MkdirAll(dbDir, 0755); err != nil {
		log.Fatalf("创建数据库目录失败: %v", err)
	}

	// 2. 连接 SQLite 数据库 (启用 _pragma 优化并发读取性能)
	var err error
	DB, err = gorm.Open(sqlite.Open(dbFile+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
	if err != nil {
		log.Fatalf("连接 SQLite 数据库失败: %v", err)
	}

	// 3. 建唯一索引前先清理历史重复行，否则 AutoMigrate 会失败
	dedupeReadingProgress()

	// 4. 自动迁移数据表结构
	err = DB.AutoMigrate(
		&models.User{},
		&models.ReadingProgress{},
		&models.Bookmark{},
		&models.Favorite{},
		&models.LibraryFileIndex{},
	)
	if err != nil {
		log.Fatalf("数据库表自动迁移失败: %v", err)
	}

	log.Printf("SQLite 数据库初始化成功 (存储路径: %s)", dbFile)
}

// dedupeReadingProgress 对同一 (user_id, book_id) 只保留 client_updated_at 最大的一行。
// 老版本缺唯一索引时可能已写入重复行，直接建索引会报 UNIQUE constraint failed。
func dedupeReadingProgress() {
	if !DB.Migrator().HasTable(&models.ReadingProgress{}) {
		return
	}

	result := DB.Exec(`
		DELETE FROM reading_progresses
		WHERE id NOT IN (
			SELECT id FROM (
				SELECT id FROM reading_progresses AS p
				WHERE p.rowid = (
					SELECT q.rowid FROM reading_progresses AS q
					WHERE q.user_id = p.user_id AND q.book_id = p.book_id
					ORDER BY q.client_updated_at DESC, q.rowid DESC
					LIMIT 1
				)
			)
		)`)
	if result.Error != nil {
		log.Printf("清理 reading_progresses 重复行失败: %v", result.Error)
		return
	}
	if result.RowsAffected > 0 {
		log.Printf("已清理 %d 条重复的阅读进度记录（保留时间戳最新的一条）", result.RowsAffected)
	}
}
