package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
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

// BrowseDirectory 浏览目录（使用 safe_path 防穿越与越界）
func BrowseDirectory(c *gin.Context) {
	reqPath := c.DefaultQuery("path", "/")

	// 垃圾箱是唯一允许浏览的隐藏目录，其余隐藏目录一律拒绝
	if !utils.IsHiddenPathAllowed(reqPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许浏览隐藏目录"})
		return
	}

	inUploads := utils.IsUploadsPath(reqPath)

	// 1. 安全解析目标目录物理绝对路径（自动区分 NAS 书库与上传目录两个根）
	targetDir, _, err := utils.ResolveLibraryPath(reqPath)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	// 浏览垃圾箱时按需创建，避免首次进入报 404
	if utils.NormalizeRelPath(reqPath) == "/"+utils.TrashBinDirName {
		if _, mkErr := utils.ResolveTrashBinDir(); mkErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱目录: " + mkErr.Error()})
			return
		}
	}

	entries, err := os.ReadDir(targetDir)
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

	// 相对路径的计算基准与展示前缀随所属根目录切换
	relRoot := utils.GetNasRootDir()
	pathPrefix := ""
	if inUploads {
		relRoot = utils.GetUploadsRootDir()
		pathPrefix = "/" + utils.UploadsPathPrefix
	}

	nodes := collectBookNodes(entries, targetDir, relRoot, pathPrefix)

	// 在书库根目录额外注入“上传书籍”虚拟目录（仅当上传目录里确实有书时）
	if utils.NormalizeRelPath(reqPath) == "/" && uploadsHasBooks() {
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

// collectBookNodes 把目录条目转换为 FileNode：过滤隐藏项，非目录仅保留受支持的电子书格式。
// relRoot 为相对路径计算基准，pathPrefix 为返回路径统一附加的虚拟前缀（上传目录用）。
func collectBookNodes(entries []os.DirEntry, targetDir, relRoot, pathPrefix string) []FileNode {
	var nodes []FileNode
	for _, entry := range entries {
		name := entry.Name()
		// 忽略隐藏文件及文件夹（.DS_Store, .git, .trashBin 等）
		if strings.HasPrefix(name, ".") {
			continue
		}

		fullEntryPath := filepath.Join(targetDir, name)
		info, infoErr := entry.Info()
		if infoErr != nil {
			continue
		}

		relPath, relErr := filepath.Rel(relRoot, fullEntryPath)
		if relErr != nil {
			continue
		}

		// 统一斜杠分隔符，确保多平台与前端路径一致
		standardRelPath := pathPrefix + "/" + filepath.ToSlash(relPath)

		if entry.IsDir() {
			nodes = append(nodes, FileNode{
				Name:    name,
				Path:    standardRelPath,
				IsDir:   true,
				Size:    0,
				ModTime: info.ModTime().UnixMilli(),
			})
		} else {
			ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
			if IsSupportedBookExt(ext) {
				nodes = append(nodes, FileNode{
					Name:      name,
					Path:      standardRelPath,
					IsDir:     false,
					Size:      info.Size(),
					Extension: ext,
					BookID:    GenerateFastFileFingerprint(fullEntryPath, info.Size()),
					ModTime:   info.ModTime().UnixMilli(),
				})
			}
		}
	}
	return nodes
}

// uploadsHasBooks 判断上传目录内是否至少有一本受支持的电子书
func uploadsHasBooks() bool {
	root := utils.GetUploadsRootDir()
	found := false
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") {
			return nil
		}
		if IsSupportedBookExt(strings.TrimPrefix(filepath.Ext(d.Name()), ".")) {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
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

	// 1. 使用 safe_path 校验并解析目标绝对路径（自动区分 NAS 书库与上传目录）
	targetFilePath, _, err := utils.ResolveLibraryPath(relPath)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	// 2. 检查目标是否存在且非目录
	fileInfo, err := os.Stat(targetFilePath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}

	if fileInfo.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标为目录，不支持直接下载"})
		return
	}

	// 3. 电子书格式白名单（防止读取目录下的隐藏敏感文件）
	if !IsSupportedBookFile(targetFilePath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不支持下载非电子书文件"})
		return
	}

	// 4. 设置安全下载头（兼容中文文件名）
	filename := filepath.Base(targetFilePath)
	c.Header("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(filename))

	// 5. 传输文件（支持 HTTP Range 断点续传）
	c.File(targetFilePath)
}

// GenerateFastFileFingerprint 快速指纹算法：SHA256(前4KB + 后4KB + 文件大小)
func GenerateFastFileFingerprint(filePath string, size int64) string {
	file, err := os.Open(filePath)
	if err != nil {
		return ""
	}
	defer file.Close()

	hasher := sha256.New()
	headBuf := make([]byte, 4096)
	n, _ := file.Read(headBuf)
	hasher.Write(headBuf[:n])

	if size > 4096 {
		tailBuf := make([]byte, 4096)
		offset := size - 4096
		if offset < 4096 {
			offset = 4096
		}
		_, _ = file.Seek(offset, io.SeekStart)
		n, _ = file.Read(tailBuf)
		hasher.Write(tailBuf[:n])
	}

	hasher.Write([]byte(fmt.Sprintf("%d", size)))
	return hex.EncodeToString(hasher.Sum(nil))
}
