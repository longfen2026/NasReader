package handlers

import (
	"errors"
	"net/http"
	"path/filepath"
	"reader-sync/storage"
	"reader-sync/utils"
	"sort"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

// searchResultLimit 单次全库搜索返回的最大结果数。
// 书库无索引，命中项还要逐个计算文件指纹，因此必须设上限防止过泛关键词拖垮 NAS。
const searchResultLimit = 200

// errSearchLimitReached 内部哨兵错误，命中数达到上限时用于立即终止整棵目录遍历。
var errSearchLimitReached = errors.New("search result limit reached")

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

	backend := storage.Get()
	lowerKeyword := strings.ToLower(keyword)
	nodes := make([]FileNode, 0, 32)
	truncated := false

	// walkRoot 递归遍历一个逻辑根目录，命中受支持电子书且文件名含关键词时收集为 FileNode。
	// 返回 true 表示已达上限，调用方应停止遍历后续根目录。
	walkRoot := func(root string) bool {
		reachedLimit := false
		walkErr := backend.Walk(root, func(info storage.FileInfo) error {
			name := info.Name

			if info.IsDir {
				// 跳过隐藏目录整棵子树（垃圾箱 .trashBin 等），根目录自身不做隐藏判定
				if info.Path != root && strings.HasPrefix(name, ".") {
					return storage.ErrSkipSubtree
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

			nodes = append(nodes, FileNode{
				Name:      name,
				Path:      info.Path,
				IsDir:     false,
				Size:      info.Size,
				Extension: ext,
				BookID:    backend.Fingerprint(info.Path, info.Size),
				ModTime:   info.ModTime.UnixMilli(),
			})
			if len(nodes) >= limit {
				reachedLimit = true
				return errSearchLimitReached
			}
			return nil
		})
		if walkErr != nil && !errors.Is(walkErr, errSearchLimitReached) {
			// 其他遍历错误（如根目录不存在）忽略，继续尝试后续根目录
			return reachedLimit
		}
		return reachedLimit
	}

	if walkRoot("/") {
		truncated = true
	} else {
		// NAS 书库未占满配额时，继续在上传目录里搜索并合并结果
		if walkRoot("/" + utils.UploadsPathPrefix) {
			truncated = true
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
