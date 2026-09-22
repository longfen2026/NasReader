package main

import (
	"log"
	"net/http"
	"os"
	"reader-sync/config"
	"reader-sync/handlers"
	"reader-sync/middleware"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// allowedOrigins 解析 CORS_ALLOWED_ORIGINS（逗号分隔）。为空表示不放行任何跨域请求。
func allowedOrigins() map[string]bool {
	raw := strings.TrimSpace(os.Getenv("CORS_ALLOWED_ORIGINS"))
	origins := make(map[string]bool)
	if raw == "" {
		return origins
	}
	for _, item := range strings.Split(raw, ",") {
		if o := strings.TrimSpace(item); o != "" {
			origins[o] = true
		}
	}
	return origins
}

func corsMiddleware() gin.HandlerFunc {
	origins := allowedOrigins()
	if len(origins) == 0 {
		log.Println("CORS: 未配置 CORS_ALLOWED_ORIGINS，将拒绝所有浏览器跨域请求（原生客户端不受影响）")
	}

	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" && origins[origin] {
			c.Writer.Header().Set("Access-Control-Allow-Origin", origin)
			c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
			c.Writer.Header().Set("Vary", "Origin")
			c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
			c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")
		}

		if c.Request.Method == http.MethodOptions {
			if origin != "" && !origins[origin] {
				c.AbortWithStatus(http.StatusForbidden)
				return
			}
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

func main() {
	middleware.InitJwtSecret()
	handlers.InitInviteCode()
	config.InitDB()

	handlers.AuthLimiter.StartCleanup(10 * time.Minute)

	r := gin.Default()

	r.Use(corsMiddleware())

	api := r.Group("/api/v1")
	{
		// 开放接口：健康探针，供客户端主备服务器切换时探测可用性
		api.GET("/health", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{"status": "ok"})
		})

		// 开放接口：用户注册与登录
		authGroup := api.Group("/auth")
		authGroup.Use(middleware.AuthRateLimit(handlers.AuthLimiter))
		{
			authGroup.POST("/register", handlers.Register)
			authGroup.POST("/login", handlers.Login)
		}

		// 账号维护接口：需登录态，且沿用登录失败频率限制
		accountGroup := api.Group("/auth")
		accountGroup.Use(middleware.AuthRateLimit(handlers.AuthLimiter), middleware.AuthMiddleware())
		{
			accountGroup.POST("/password", handlers.ChangePassword)
		}

		// 受保护接口：需携带 JWT Token
		syncGroup := api.Group("/sync")
		syncGroup.Use(middleware.AuthMiddleware())
		{
			// 1. 阅读进度同步
			syncGroup.GET("/progress", handlers.GetAllProgress)
			syncGroup.GET("/progress/:book_id", handlers.GetProgress)
			syncGroup.POST("/progress", handlers.SyncProgress)

			// 2. 书签双向同步 (新增)
			syncGroup.GET("/bookmarks/:book_id", handlers.GetBookmarks)
			syncGroup.POST("/bookmarks", handlers.SyncBookmarks)

			// 3. 收藏夹双向同步
			syncGroup.GET("/favorites", handlers.GetFavorites)
			syncGroup.POST("/favorites", handlers.SyncFavorites)

			// 4. 批量删除书籍云端记录（进度 + 书签 + 收藏）
			syncGroup.POST("/delete", handlers.DeleteBookSyncData)
		}

		// 文件系统相关接口
		fileGroup := api.Group("/files")
		fileGroup.Use(middleware.AuthMiddleware())
		{
			fileGroup.GET("/browse", handlers.BrowseDirectory)
			fileGroup.GET("/search", handlers.SearchBooks)
			fileGroup.GET("/download", handlers.DownloadFile)
			fileGroup.POST("/upload", handlers.UploadBook)
			fileGroup.POST("/trash", handlers.MoveToTrash)
			fileGroup.POST("/trash/restore", handlers.RestoreFromTrash)
			fileGroup.POST("/trash/refresh", handlers.RefreshTrashBin)
		}
	}

	log.Println("Reader Sync Server started on :8080")
	if err := r.Run(":8080"); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}
