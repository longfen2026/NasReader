// utils/safe_path.go
package utils

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// 获取 NAS 书籍根目录（优先从环境变量读取）
func GetNasRootDir() string {
	root := os.Getenv("NAS_BOOKS_DIR")
	if root == "" {
		root = "/data/books" // 默认容器挂载点
	}
	return filepath.Clean(root)
}

// GetUploadsRootDir 获取用户上传书籍的根目录（通过 UPLOADS_DIR 挂载）
func GetUploadsRootDir() string {
	root := os.Getenv("UPLOADS_DIR")
	if root == "" {
		root = "/app/uploads" // 默认容器挂载点
	}
	return filepath.Clean(root)
}

// UploadsPathPrefix 上传目录在书库浏览中的虚拟路径前缀。
// 它不出现在真实磁盘上，仅作为前端路由标识，用于把上传目录与 NAS 书库合并展示。
const UploadsPathPrefix = "__uploads__"

// UploadsDisplayName 上传虚拟目录在前端列表中的展示名称
const UploadsDisplayName = "上传书籍"

// IsUploadsPath 判断用户路径是否指向上传虚拟目录本身或其内部
func IsUploadsPath(relPath string) bool {
	norm := NormalizeRelPath(relPath)
	return norm == "/"+UploadsPathPrefix || strings.HasPrefix(norm, "/"+UploadsPathPrefix+"/")
}

// safeResolveUnder 在指定 root 下安全解析用户相对路径，拦截任何跨目录遍历
func safeResolveUnder(root, userPath string) (string, error) {
	cleanUserPath := filepath.Clean("/" + userPath)
	targetPath := filepath.Join(root, cleanUserPath)

	rel, err := filepath.Rel(root, targetPath)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", errors.New("非法访问：检测到跨目录遍历攻击")
	}
	return targetPath, nil
}

// SafeResolvePath 强制校验路径合法性，拦截任何跳出 NAS 书库根目录的攻击
func SafeResolvePath(userPath string) (string, error) {
	return safeResolveUnder(GetNasRootDir(), userPath)
}

// ResolveLibraryPath 把用户路径解析为物理路径，自动区分 NAS 书库与上传目录两个根。
// 返回：物理绝对路径、是否属于上传目录、错误。
func ResolveLibraryPath(userPath string) (string, bool, error) {
	if IsUploadsPath(userPath) {
		sub := strings.TrimPrefix(NormalizeRelPath(userPath), "/"+UploadsPathPrefix)
		abs, err := safeResolveUnder(GetUploadsRootDir(), sub)
		return abs, true, err
	}
	abs, err := SafeResolvePath(userPath)
	return abs, false, err
}

// TrashBinDirName 垃圾箱目录名，位于 NAS 根目录下且不出现在常规目录浏览结果中
const TrashBinDirName = ".trashBin"

// NormalizeRelPath 归一化用户传入的相对路径为以 / 开头的 slash 分隔形式
func NormalizeRelPath(userPath string) string {
	return filepath.ToSlash(filepath.Clean("/" + userPath))
}

// IsHiddenPathAllowed 隐藏路径一律拒绝，仅放行根目录下的垃圾箱这一个例外
func IsHiddenPathAllowed(relPath string) bool {
	segments := strings.Split(strings.Trim(NormalizeRelPath(relPath), "/"), "/")
	for i, seg := range segments {
		if seg == "" || !strings.HasPrefix(seg, ".") {
			continue
		}
		if i != 0 || seg != TrashBinDirName {
			return false
		}
	}
	return true
}

// IsInTrashBin 判断相对路径是否指向垃圾箱本身或其内部
func IsInTrashBin(relPath string) bool {
	norm := NormalizeRelPath(relPath)
	return norm == "/"+TrashBinDirName || strings.HasPrefix(norm, "/"+TrashBinDirName+"/")
}

// ResolveTrashBinDir 返回垃圾箱物理目录，必要时创建
func ResolveTrashBinDir() (string, error) {
	dir := filepath.Join(GetNasRootDir(), TrashBinDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}
