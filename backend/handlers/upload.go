package handlers

import (
	"net/http"
	"path/filepath"
	"reader-sync/storage"
	"reader-sync/utils"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// maxUploadSize 单本书籍上传的体积上限，防止超大文件塞满 NAS
const maxUploadSize = 512 << 20 // 512 MiB

// UploadBook 接收前端上传的电子书并保存到上传目录（底层存储由 storage.Backend 决定）。
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

	backend := storage.Get()

	// 在上传目录下选一个不冲突的逻辑路径（重名追加序号）
	relPath, err := uniqueUploadRelPath(backend, safeName)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法确定保存路径: " + err.Error()})
		return
	}

	src, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取上传流: " + err.Error()})
		return
	}
	defer src.Close()

	if err := backend.Create(relPath, src); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败: " + err.Error()})
		return
	}

	info, err := backend.Stat(relPath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取已保存文件失败"})
		return
	}

	name := filepath.Base(utils.NormalizeRelPath(relPath))
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))

	c.JSON(http.StatusOK, gin.H{
		"code":    200,
		"message": "上传成功",
		"item": FileNode{
			Name:      name,
			Path:      relPath,
			IsDir:     false,
			Size:      info.Size,
			Extension: ext,
			BookID:    backend.Fingerprint(relPath, info.Size),
			ModTime:   info.ModTime.UnixMilli(),
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

// uniqueUploadRelPath 在上传目录内寻找一个尚不存在的逻辑路径，重名时追加 (n) 序号。
func uniqueUploadRelPath(backend storage.Backend, name string) (string, error) {
	prefix := "/" + utils.UploadsPathPrefix + "/"
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)

	candidate := prefix + name
	for i := 1; ; i++ {
		exists, err := backend.Exists(candidate)
		if err != nil {
			return "", err
		}
		if !exists {
			return candidate, nil
		}
		candidate = prefix + base + "(" + strconv.Itoa(i) + ")" + ext
	}
}
