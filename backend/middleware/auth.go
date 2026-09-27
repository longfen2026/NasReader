package middleware

import (
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"reader-sync/config"
	"reader-sync/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// JWT 密钥最小长度，低于此长度的 HS256 密钥容易被离线爆破
const minJwtSecretLength = 32

type Claims struct {
	UserID       string `json:"user_id"`
	Username     string `json:"username"`
	TokenVersion int    `json:"token_version"`
	jwt.RegisteredClaims
}

var jwtSecret []byte

// InitJwtSecret 必须在启动阶段调用：密钥缺失或过弱时直接终止进程，
// 避免使用可预测的默认密钥导致任意用户身份被伪造。
func InitJwtSecret() {
	secret := strings.TrimSpace(os.Getenv("JWT_SECRET"))
	if secret == "" {
		log.Fatal("启动失败: 必须设置环境变量 JWT_SECRET（建议 32 字节以上随机字符串）")
	}
	if len(secret) < minJwtSecretLength {
		log.Fatalf("启动失败: JWT_SECRET 长度不足 %d 字节，请使用更强的随机密钥", minJwtSecretLength)
	}
	jwtSecret = []byte(secret)
}

func GetJwtSecret() []byte {
	if len(jwtSecret) == 0 {
		log.Fatal("JWT 密钥未初始化，请在启动时调用 middleware.InitJwtSecret()")
	}
	return jwtSecret
}

// GenerateToken 生成 7 天有效期的 JWT，tokenVersion 写入令牌用于后续吊销校验
func GenerateToken(userID, username string, tokenVersion int) (string, error) {
	claims := Claims{
		UserID:       userID,
		Username:     username,
		TokenVersion: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(7 * 24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(GetJwtSecret())
}

// AuthMiddleware 验证请求头中的 Bearer Token
func AuthMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Authorization header required (Bearer <token>)"})
			c.Abort()
			return
		}

		tokenString := strings.TrimPrefix(authHeader, "Bearer ")
		token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
			return GetJwtSecret(), nil
		}, jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}))

		if err != nil || !token.Valid {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid or expired token"})
			c.Abort()
			return
		}

		claims, ok := token.Claims.(*Claims)
		if !ok {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid token claims"})
			c.Abort()
			return
		}

		// 比对令牌版本，改密等操作会自增 DB 中的 TokenVersion，令旧令牌立即失效
		var user models.User
		if err := config.DB.Select("token_version").Where("id = ?", claims.UserID).First(&user).Error; err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid or expired token"})
			c.Abort()
			return
		}
		if user.TokenVersion != claims.TokenVersion {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Token has been revoked"})
			c.Abort()
			return
		}

		// 将用户 ID 注入请求上下文
		c.Set("user_id", claims.UserID)
		c.Set("username", claims.Username)
		c.Next()
	}
}
