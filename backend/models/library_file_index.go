// models/library_file_index.go
package models

// LibraryFileIndex 全库电子书索引：记录每个文件的逻辑路径、内容指纹与元数据。
// 用于书籍更新（指纹变化）后的阅读记录对账迁移。
// Size/ModTime 作为增量缓存依据：两者都没变时直接复用已算好的 BookID，避免重复读文件头尾。
type LibraryFileIndex struct {
	Path      string `gorm:"primaryKey;type:varchar(512)" json:"path"` // 逻辑相对路径，如 /科幻/三体.epub
	BookID    string `gorm:"index;type:varchar(64)" json:"book_id"`    // 内容指纹（SHA256 前4KB+后4KB+size）
	Name      string `gorm:"type:varchar(255)" json:"name"`            // 文件名（含扩展名）
	Extension string `gorm:"type:varchar(16)" json:"extension"`
	Size      int64  `gorm:"not null;default:0" json:"size"`
	ModTime   int64  `gorm:"not null;default:0" json:"mod_time"` // 毫秒时间戳
}
