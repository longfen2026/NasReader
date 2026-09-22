package handlers

import (
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"reader-sync/utils"
	"strings"

	"github.com/gin-gonic/gin"
)

// maxUploadSize 单本书籍上传的体积上限，防止超大文件塞满 NAS
const maxUploadSize = 512 << 20 // 512 MiB

// UploadBook 接收前端上传的电子书并保存到 UPLOADS_DIR。
// 文件名经过消毒，仅允许受支持的电子书格式，重名自动追加序号避免覆盖。
func UploadBook(c *gin.Context) {
	// 限制请求体尺寸，抵御超大 body 造成的内存/磁盘耗尽
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxUploadSize)

	fileHeader, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少上传文件字段 file: " + err.Error()})
		return
	}

	if fileHeader.Size > maxUploadSize {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "文件超过大小上限 512MB"})
		return
	}

	// 仅取基础名并剔除路径分隔符，杜绝借文件名穿越目录
	safeName := sanitizeUploadFileName(fileHeader.Filename)
	if safeName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "非法文件名"})
		return
	}

	if !IsSupportedBookFile(safeName) {
		c.JSON(http.StatusUnsupportedMediaType, gin.H{"error": "仅支持上传电子书文件（txt/epub/mobi/pdf）"})
		return
	}

	uploadsRoot := utils.GetUploadsRootDir()
	if err := os.MkdirAll(uploadsRoot, 0o755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建上传目录: " + err.Error()})
		return
	}

	destPath := uniqueDestPath(uploadsRoot, safeName)

	if err := saveUploadedFile(fileHeader, destPath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败: " + err.Error()})
		return
	}

	info, err := os.Stat(destPath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取已保存文件失败"})
		return
	}

	name := filepath.Base(destPath)
	relPath := "/" + utils.UploadsPathPrefix + "/" + name
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))

	c.JSON(http.StatusOK, gin.H{
		"code":    200,
		"message": "上传成功",
		"item": FileNode{
			Name:      name,
			Path:      relPath,
			IsDir:     false,
			Size:      info.Size(),
			Extension: ext,
			BookID:    GenerateFastFileFingerprint(destPath, info.Size()),
			ModTime:   info.ModTime().UnixMilli(),
		},
	})
}

// sanitizeUploadFileName 仅保留文件基础名，去除任何目录成分与前后空白，
// 空名或以点号开头（隐藏文件）一律视为非法返回空串。
func sanitizeUploadFileName(raw string) string {
	// 兼容 Windows 反斜杠路径，全部归一到基础名
	name := filepath.Base(strings.ReplaceAll(raw, "\\", "/"))
	name = strings.TrimSpace(name)
	if name == "" || name == "." || name == ".." || strings.HasPrefix(name, ".") {
		return ""
	}
	return name
}

// saveUploadedFile 把 multipart 文件流写入目标路径（O_EXCL 防止竞争覆盖）
func saveUploadedFile(fh *multipart.FileHeader, dest string) error {
	src, err := fh.Open()
	if err != nil {
		return err
	}
	defer src.Close()

	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, src); err != nil {
		out.Close()
		os.Remove(dest)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(dest)
		return err
	}
	return nil
}
