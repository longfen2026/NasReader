package models

import "time"

type User struct {
	ID       string `gorm:"primaryKey;type:varchar(36)" json:"id"`
	Username string `gorm:"uniqueIndex;not null;type:varchar(50)" json:"username"`
	Password string `gorm:"not null" json:"-"` // 不返回前端
	// TokenVersion 随改密等操作自增，用于吊销旧 JWT：签发时写入令牌，校验时比对，不一致即失效
	TokenVersion int       `gorm:"not null;default:0" json:"-"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}
