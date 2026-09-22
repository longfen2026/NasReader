package handlers

import (
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"reader-sync/utils"
	"sort"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// searchResultLimit 单次全库搜索返回的最大结果数。
// 书库无索引，命中项还要逐个计算文件指纹，因此必须设上限防止过泛关键词拖垮 NAS。
const searchResultLimit = 200

// SearchBooks 按文件名关键词递归搜索整个书库中的电子书。
// 隐藏目录（含垃圾箱 .trashBin）整棵子树跳过，因此已删除的书籍不会在搜索结果中重现。
func SearchBooks(c *gin.Context) {
	keyword := strings.TrimSpace(c.Query("q"))
	if keyword == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少搜索关键词 q"})
		return
	}

	limit := searchResultLimit
	if raw := c.Query("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed < searchResultLimit {
			limit = parsed
		}
	}

	nasRoot := utils.GetNasRootDir()
	if info, err := os.Stat(nasRoot); err != nil || !info.IsDir() {
		log.Printf("搜索失败：书库根目录不可用 %s: %v", nasRoot, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "书库根目录不可用"})
		return
	}

	lowerKeyword := strings.ToLower(keyword)
	nodes := make([]FileNode, 0, 32)
	truncated := false

	// 关键词命中回调：把文件转成 FileNode 收集起来，达到上限即中止整次遍历。
	// relRoot 为相对路径基准，pathPrefix 为返回路径统一附加的虚拟前缀（上传目录用）。
	collect := func(fullPath, name string, d fs.DirEntry, relRoot, pathPrefix string) bool {
		info, err := d.Info()
		if err != nil {
			return false
		}
		relPath, err := filepath.Rel(relRoot, fullPath)
		if err != nil {
			return false
		}
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
		nodes = append(nodes, FileNode{
			Name:      name,
			Path:      pathPrefix + "/" + filepath.ToSlash(relPath),
			IsDir:     false,
			Size:      info.Size(),
			Extension: ext,
			BookID:    GenerateFastFileFingerprint(fullPath, info.Size()),
			ModTime:   info.ModTime().UnixMilli(),
		})
		return len(nodes) >= limit
	}

	// walkRoot 递归遍历一个根目录，命中受支持电子书且文件名含关键词时调用 collect。
	// 返回 true 表示已达上限，调用方应停止遍历后续根目录。
	walkRoot := func(root, pathPrefix string) bool {
		reachedLimit := false
		_ = filepath.WalkDir(root, func(fullPath string, d fs.DirEntry, entryErr error) error {
			// 单个条目不可读时跳过，不让局部权限问题打断整次搜索
			if entryErr != nil {
				if d != nil && d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}

			name := d.Name()

			if d.IsDir() {
				// 根目录自身可能以点号开头（如自定义挂载点），只对子目录做隐藏判定
				if fullPath != root && strings.HasPrefix(name, ".") {
					return fs.SkipDir
				}
				return nil
			}

			if strings.HasPrefix(name, ".") {
				return nil
			}

			ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
			if !IsSupportedBookExt(ext) {
				return nil
			}

			if !strings.Contains(strings.ToLower(name), lowerKeyword) {
				return nil
			}

			// 指纹计算需要读文件头尾，只对命中项执行，未命中项全程仅做字符串比较
			if collect(fullPath, name, d, root, pathPrefix) {
				reachedLimit = true
				return fs.SkipAll
			}
			return nil
		})
		return reachedLimit
	}

	if walkRoot(nasRoot, "") {
		truncated = true
	} else {
		// NAS 书库未占满配额时，继续在上传目录里搜索并合并结果
		uploadsRoot := utils.GetUploadsRootDir()
		if info, err := os.Stat(uploadsRoot); err == nil && info.IsDir() {
			if walkRoot(uploadsRoot, "/"+utils.UploadsPathPrefix) {
				truncated = true
			}
		}
	}

	// 结果按名称升序，与书库默认排序的认知保持一致
	sort.Slice(nodes, func(i, j int) bool {
		return strings.ToLower(nodes[i].Name) < strings.ToLower(nodes[j].Name)
	})

	c.JSON(http.StatusOK, gin.H{
		"keyword":   keyword,
		"items":     nodes,
		"truncated": truncated,
	})
}
