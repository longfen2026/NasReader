package handlers

import (
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reader-sync/storage"
	"reader-sync/utils"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// supportedBookExts 支持的电子书格式白名单（不含点号），需与前端 BookFormat 保持一致
var supportedBookExts = map[string]bool{
	"txt":  true,
	"epub": true,
	"mobi": true,
	"pdf":  true,
}

// IsSupportedBookExt 判断扩展名是否为受支持的电子书格式，入参可带或不带点号
func IsSupportedBookExt(ext string) bool {
	return supportedBookExts[strings.ToLower(strings.TrimPrefix(ext, "."))]
}

// IsSupportedBookFile 判断文件名/路径是否为受支持的电子书
func IsSupportedBookFile(name string) bool {
	return IsSupportedBookExt(filepath.Ext(name))
}

// FileNode 目录树节点结构
type FileNode struct {
	Name      string `json:"name"`
	Path      string `json:"path"` // 统一的相对路径，如 /科幻/三体.epub
	IsDir     bool   `json:"is_dir"`
	Size      int64  `json:"size"`
	Extension string `json:"extension,omitempty"` // txt / epub / pdf
	BookID    string `json:"book_id,omitempty"`   // 文件的唯一指纹（用于跨设备精确同步）
	ModTime   int64  `json:"mod_time"`
}

// BrowseDirectory 浏览目录（使用 safe_path 防穿越与越界，底层存储由 storage.Backend 决定）
func BrowseDirectory(c *gin.Context) {
	reqPath := c.DefaultQuery("path", "/")

	// 垃圾箱是唯一允许浏览的隐藏目录，其余隐藏目录一律拒绝
	if !utils.IsHiddenPathAllowed(reqPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许浏览隐藏目录"})
		return
	}

	inUploads := utils.IsUploadsPath(reqPath)
	backend := storage.Get()

	// 浏览垃圾箱时按需创建，避免首次进入报 404（仅本地后端需要，WebDAV 由远端自身处理）
	if utils.NormalizeRelPath(reqPath) == "/"+utils.TrashBinDirName {
		_ = backend.MkdirAll("/" + utils.TrashBinDirName)
	}

	entries, err := backend.ReadDir(reqPath)
	if err != nil {
		// 上传目录尚未创建（无人上传过）时，返回空列表而非 404
		if os.IsNotExist(err) && inUploads {
			c.JSON(http.StatusOK, gin.H{"current_path": reqPath, "items": []FileNode{}})
			return
		}
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "目录不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取目录: " + err.Error()})
		return
	}

	nodes := collectBookNodes(backend, entries)

	// 在书库根目录额外注入“上传书籍”虚拟目录（仅当上传目录里确实有书时）
	if utils.NormalizeRelPath(reqPath) == "/" && uploadsHasBooks(backend) {
		nodes = append([]FileNode{{
			Name:    utils.UploadsDisplayName,
			Path:    "/" + utils.UploadsPathPrefix,
			IsDir:   true,
			Size:    0,
			ModTime: time.Now().UnixMilli(),
		}}, nodes...)
	}

	c.JSON(http.StatusOK, gin.H{
		"current_path": reqPath,
		"items":        nodes,
	})
}

// collectBookNodes 把 backend 返回的目录条目转换为 FileNode：过滤隐藏项，非目录仅保留受支持的电子书格式。
func collectBookNodes(backend storage.Backend, entries []storage.FileInfo) []FileNode {
	var nodes []FileNode
	for _, entry := range entries {
		name := entry.Name
		// 忽略隐藏文件及文件夹（.DS_Store, .git, .trashBin 等）
		if strings.HasPrefix(name, ".") {
			continue
		}

		if entry.IsDir {
			nodes = append(nodes, FileNode{
				Name:    name,
				Path:    entry.Path,
				IsDir:   true,
				Size:    0,
				ModTime: entry.ModTime.UnixMilli(),
			})
		} else {
			ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
			if IsSupportedBookExt(ext) {
				nodes = append(nodes, FileNode{
					Name:      name,
					Path:      entry.Path,
					IsDir:     false,
					Size:      entry.Size,
					Extension: ext,
					BookID:    backend.Fingerprint(entry.Path, entry.Size),
					ModTime:   entry.ModTime.UnixMilli(),
				})
			}
		}
	}
	return nodes
}

// uploadsHasBooks 判断上传目录内是否至少有一本受支持的电子书（只看当前层，够用且省网络）
func uploadsHasBooks(backend storage.Backend) bool {
	entries, err := backend.ReadDir("/" + utils.UploadsPathPrefix)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir || strings.HasPrefix(e.Name, ".") {
			continue
		}
		if IsSupportedBookExt(strings.TrimPrefix(filepath.Ext(e.Name), ".")) {
			return true
		}
	}
	return false
}

// DownloadFile 安全下载电子书文件
func DownloadFile(c *gin.Context) {
	relPath := c.Query("path")
	if relPath == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少 path 参数"})
		return
	}

	if !utils.IsHiddenPathAllowed(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许访问隐藏目录"})
		return
	}

	// 1. 校验并解析目标路径（safe_path 防穿越，两个存储后端共用同一套逻辑路径）
	if _, _, err := utils.ResolveLibraryPath(relPath); err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	// 2. 电子书格式白名单（防止读取目录下的隐藏敏感文件）
	if !IsSupportedBookFile(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不支持下载非电子书文件"})
		return
	}

	backend := storage.Get()
	reader, info, err := backend.Open(relPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件: " + err.Error()})
		return
	}
	defer reader.Close()

	if info.IsDir {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标为目录，不支持直接下载"})
		return
	}

	// 3. 设置安全下载头（兼容中文文件名）
	filename := filepath.Base(utils.NormalizeRelPath(relPath))
	c.Header("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(filename))

	// 4. 本地文件走 c.File 以支持 Range 断点续传；远端则流式转发
	if f, ok := reader.(*os.File); ok {
		c.File(f.Name())
		return
	}
	c.DataFromReader(http.StatusOK, info.Size, "application/octet-stream", reader, nil)
}
