// handlers/delete.go
package handlers

import (
	"net/http"
	"reader-sync/config"
	"reader-sync/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type DeleteBookRequest struct {
	BookID string `json:"book_id" binding:"required"`
}

func DeleteBookSyncData(c *gin.Context) {
	// 1. 唯一信任 Token 注入的 user_id
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req DeleteBookRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	db := config.DB

	// 2. 事务中物理删除该用户此书籍的进度和书签
	err := db.Transaction(func(tx *gorm.DB) error {
		// 删除进度
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.ReadingProgress{}).Error; err != nil {
			return err
		}

		// 删除书签
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.Bookmark{}).Error; err != nil {
			return err
		}

		// 删除收藏
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.Favorite{}).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "批量删除数据失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":    200,
		"message": "书籍云端阅读记录、书签与收藏已彻底删除",
		"book_id": req.BookID,
	})
}

// RemoveBookReadingData deletes only the user's reading progress and bookmarks.
// Favorites and the NAS source file are intentionally left untouched.
func RemoveBookReadingData(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req DeleteBookRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	err := config.DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.ReadingProgress{}).Error; err != nil {
			return err
		}
		return tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.Bookmark{}).Error
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除云端阅读记录和书签失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":    200,
		"message": "书籍云端阅读记录和书签已删除",
		"book_id": req.BookID,
	})
}
