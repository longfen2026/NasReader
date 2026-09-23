// handlers/trash.go
package handlers

import (
	"fmt"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"reader-sync/storage"
	"reader-sync/utils"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type MoveToTrashRequest struct {
	Path string `json:"path" binding:"required"`
}

// MoveToTrash 把 NAS 书库中的电子书移动到根目录下的 .trashBin，保留原有子目录层级
func MoveToTrash(c *gin.Context) {
	var req MoveToTrashRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	relPath := utils.NormalizeRelPath(req.Path)
	if relPath == "/" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不允许操作书库根目录"})
		return
	}
	if utils.IsInTrashBin(relPath) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该文件已在垃圾箱中"})
		return
	}
	if !utils.IsHiddenPathAllowed(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许操作隐藏目录"})
		return
	}
	// 校验目标位置合法（防穿越、限定在书库根内）
	if _, err := utils.SafeResolvePath(relPath); err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	backend := storage.Get()

	info, err := backend.Stat(relPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}
	if info.IsDir {
		c.JSON(http.StatusBadRequest, gin.H{"error": "暂不支持将文件夹移入垃圾箱"})
		return
	}

	if !IsSupportedBookFile(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "仅支持移动电子书文件"})
		return
	}

	// 保留原目录结构，便于在垃圾箱里辨认书籍来源：/.trashBin/<原相对目录>/<文件名>
	trashDirRel := utils.NormalizeRelPath(path.Join("/"+utils.TrashBinDirName, path.Dir(strings.TrimPrefix(relPath, "/"))))
	if err := backend.MkdirAll(trashDirRel); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱子目录: " + err.Error()})
		return
	}

	destRel, err := uniqueDestRelPath(backend, trashDirRel, path.Base(relPath))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法确定垃圾箱路径: " + err.Error()})
		return
	}
	if err := backend.Rename(relPath, destRel); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "移动到垃圾箱失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":       200,
		"message":    "已移动到垃圾箱",
		"trash_path": destRel,
	})
}

type RestoreFromTrashRequest struct {
	Path string `json:"path" binding:"required"`
}

// RestoreFromTrash 把垃圾箱中的电子书还原到它在书库中的原始目录
func RestoreFromTrash(c *gin.Context) {
	var req RestoreFromTrashRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	relPath := utils.NormalizeRelPath(req.Path)
	if !utils.IsInTrashBin(relPath) || relPath == "/"+utils.TrashBinDirName {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能恢复垃圾箱内的文件"})
		return
	}
	if !utils.IsHiddenPathAllowed(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许操作隐藏目录"})
		return
	}

	backend := storage.Get()

	info, err := backend.Stat(relPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}
	if info.IsDir {
		c.JSON(http.StatusBadRequest, gin.H{"error": "暂不支持恢复文件夹"})
		return
	}

	if !IsSupportedBookFile(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "仅支持恢复电子书文件"})
		return
	}

	// 去掉垃圾箱前缀即得原始位置，移入时保留的子目录层级在此还原
	originRel := utils.NormalizeRelPath(strings.TrimPrefix(relPath, "/"+utils.TrashBinDirName))
	if originRel == "/" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无法确定恢复位置"})
		return
	}
	// 校验目标位置合法（防穿越、限定在书库根内）
	if _, err := utils.SafeResolvePath(originRel); err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	destDirRel := utils.NormalizeRelPath(path.Dir(strings.TrimPrefix(originRel, "/")))
	if err := backend.MkdirAll(destDirRel); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建目标目录: " + err.Error()})
		return
	}

	finalRel, err := uniqueDestRelPath(backend, destDirRel, path.Base(originRel))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法确定恢复路径: " + err.Error()})
		return
	}
	if err := backend.Rename(relPath, finalRel); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":          200,
		"message":       "已恢复到书库",
		"restored_path": finalRel,
	})
}

// RefreshTrashBin 清理垃圾箱残留：书籍被 NAS 文件管理器直接删除后，其所在的空目录会留在垃圾箱里
func RefreshTrashBin(c *gin.Context) {
	backend := storage.Get()
	if err := backend.MkdirAll("/" + utils.TrashBinDirName); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱目录: " + err.Error()})
		return
	}

	removed, err := pruneEmptyTrashDirs(backend)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "清理垃圾箱失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":          200,
		"message":       "垃圾箱已刷新",
		"removed_count": len(removed),
		"removed_dirs":  removed,
	})
}

// pruneEmptyTrashDirs 自底向上删除垃圾箱内已空的子目录，垃圾箱根自身保留，返回被删目录的逻辑路径
func pruneEmptyTrashDirs(backend storage.Backend) ([]string, error) {
	trashRootRel := "/" + utils.TrashBinDirName

	var dirs []string
	err := backend.Walk(trashRootRel, func(info storage.FileInfo) error {
		if info.IsDir && utils.NormalizeRelPath(info.Path) != trashRootRel {
			dirs = append(dirs, utils.NormalizeRelPath(info.Path))
		}
		return nil
	})
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}

	// 深的先删，父目录才可能随之变空
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })

	removed := make([]string, 0)
	for _, dir := range dirs {
		entries, readErr := backend.ReadDir(dir)
		if readErr != nil || len(entries) > 0 {
			continue
		}
		if backend.Remove(dir) != nil {
			continue
		}
		removed = append(removed, dir)
	}
	return removed, nil
}

// uniqueDestRelPath 在逻辑目录 dirRel 下寻找一个尚不存在的路径，同名文件追加时间戳避免覆盖
func uniqueDestRelPath(backend storage.Backend, dirRel, name string) (string, error) {
	join := func(n string) string {
		return utils.NormalizeRelPath(path.Join(dirRel, n))
	}

	candidate := join(name)
	exists, err := backend.Exists(candidate)
	if err != nil {
		return "", err
	}
	if !exists {
		return candidate, nil
	}

	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	stamp := time.Now().Format("20060102-150405")
	for i := 0; ; i++ {
		suffix := stamp
		if i > 0 {
			suffix = fmt.Sprintf("%s-%d", stamp, i)
		}
		candidate = join(fmt.Sprintf("%s_%s%s", base, suffix, ext))
		exists, err = backend.Exists(candidate)
		if err != nil {
			return "", err
		}
		if !exists {
			return candidate, nil
		}
	}
}
