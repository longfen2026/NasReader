package handlers

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"log"
	"net/http"
	"os"
	"reader-sync/config"
	"reader-sync/middleware"
	"reader-sync/models"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

// AuthLimiter 限制登录/注册的失败频率：15 分钟内失败 5 次即锁定 15 分钟。
var AuthLimiter = middleware.NewLoginRateLimiter(5, 15*time.Minute, 15*time.Minute)

// dummyPasswordHash 用于用户不存在时的等时比对，抵御用户名枚举。
var dummyPasswordHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-constant-time"), bcrypt.DefaultCost)

// inviteCode 为空表示关闭注册；由 InitInviteCode 在启动时读取一次。
var inviteCode string

// InitInviteCode 读取 REGISTRATION_INVITE_CODE，未设置则注册接口全程返回 403。
func InitInviteCode() {
	inviteCode = strings.TrimSpace(os.Getenv("REGISTRATION_INVITE_CODE"))
	switch {
	case inviteCode == "":
		log.Println("注册已关闭：未设置 REGISTRATION_INVITE_CODE")
	case len(inviteCode) < 8:
		log.Println("警告：REGISTRATION_INVITE_CODE 短于 8 字节，建议改用更长的随机值")
	default:
		log.Println("注册已开启：需提供邀请码")
	}
}

func registrationEnabled() bool {
	return inviteCode != ""
}

func inviteCodeMatches(provided string) bool {
	if inviteCode == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(provided)), []byte(inviteCode)) == 1
}

// RegisterRequest 注册时强制更长的密码
type RegisterRequest struct {
	Username   string `json:"username" binding:"required,min=3,max=50"`
	Password   string `json:"password" binding:"required,min=8"`
	InviteCode string `json:"inviteCode" binding:"required"`
}

// AuthRequest 登录用；保持 min=6 以便历史用户仍可登录
type AuthRequest struct {
	Username string `json:"username" binding:"required,min=3,max=50"`
	Password string `json:"password" binding:"required,min=6"`
}

// ChangePasswordRequest 修改密码；新密码沿用注册的 min=8 强度要求
type ChangePasswordRequest struct {
	OldPassword string `json:"oldPassword" binding:"required,min=6"`
	NewPassword string `json:"newPassword" binding:"required,min=8"`
}

func Register(c *gin.Context) {
	if !registrationEnabled() {
		c.JSON(http.StatusForbidden, gin.H{"error": "服务端未开放注册"})
		return
	}

	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	clientKey := c.ClientIP()
	if !inviteCodeMatches(req.InviteCode) {
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusForbidden, gin.H{"error": "邀请码无效"})
		return
	}

	var existing models.User
	if err := config.DB.Where("username = ?", req.Username).First(&existing).Error; err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "Username already exists"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to encrypt password"})
		return
	}

	randomBytes := make([]byte, 16)
	_, _ = rand.Read(randomBytes)
	userID := hex.EncodeToString(randomBytes)

	user := models.User{
		ID:       userID,
		Username: req.Username,
		Password: string(hashedPassword),
	}

	if err := config.DB.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create user"})
		return
	}

	AuthLimiter.Reset(clientKey)

	token, _ := middleware.GenerateToken(user.ID, user.Username, user.TokenVersion)
	c.JSON(http.StatusOK, gin.H{
		"message": "User registered successfully",
		"token":   token,
		"user": gin.H{
			"id":       user.ID,
			"username": user.Username,
		},
	})
}

func Login(c *gin.Context) {
	var req AuthRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	clientKey := c.ClientIP()

	var user models.User
	if err := config.DB.Where("username = ?", req.Username).First(&user).Error; err != nil {
		// 对不存在的用户也做一次哈希比对，避免通过响应耗时枚举用户名
		_ = bcrypt.CompareHashAndPassword(dummyPasswordHash, []byte(req.Password))
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid username or password"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.Password)); err != nil {
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid username or password"})
		return
	}

	token, err := middleware.GenerateToken(user.ID, user.Username, user.TokenVersion)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate token"})
		return
	}

	AuthLimiter.Reset(clientKey)

	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user": gin.H{
			"id":       user.ID,
			"username": user.Username,
		},
	})
}

// ChangePassword 修改当前登录用户的密码。
// 改密后自增 TokenVersion 使所有旧 JWT 立即失效，并下发一枚新令牌供当前会话继续使用。
func ChangePassword(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未授权"})
		return
	}

	var req ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if req.OldPassword == req.NewPassword {
		c.JSON(http.StatusBadRequest, gin.H{"error": "新密码不能与原密码相同"})
		return
	}

	var user models.User
	if err := config.DB.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return
	}

	clientKey := c.ClientIP()
	if err := bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.OldPassword)); err != nil {
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "原密码不正确"})
		return
	}

	hashed, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	// 改密同时自增 TokenVersion，使包括本次请求所用令牌在内的所有旧 JWT 立即失效
	if err := config.DB.Model(&user).Updates(map[string]interface{}{
		"password":      string(hashed),
		"token_version": user.TokenVersion + 1,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码更新失败"})
		return
	}

	AuthLimiter.Reset(clientKey)

	// 下发基于新版本号的令牌，客户端替换后可无缝继续，无需重新登录
	newToken, err := middleware.GenerateToken(user.ID, user.Username, user.TokenVersion+1)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "密码修改成功，请重新登录"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "密码修改成功",
		"token":   newToken,
	})
}
