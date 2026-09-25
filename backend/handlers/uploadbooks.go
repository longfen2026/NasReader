package handlers

import (
	"archive/zip"
	"crypto/subtle"
	_ "embed"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"reader-sync/utils"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed uploadbooks.html
var uploadBooksPageHTML string

// uploadAdminToken 为空表示 Web 上传页面完全关闭；由 InitUploadAdminToken 启动时读取一次。
var uploadAdminToken string

// uploadArchiveExts 允许上传的压缩包扩展名（不含点号），上传后可在文件浏览器中解压。
var uploadArchiveExts = map[string]bool{"zip": true}

// InitUploadAdminToken 读取 UPLOAD_ADMIN_TOKEN，未设置则整个 /uploadbooks 页面与接口一律 404。
func InitUploadAdminToken() {
	uploadAdminToken = strings.TrimSpace(os.Getenv("UPLOAD_ADMIN_TOKEN"))
	switch {
	case uploadAdminToken == "":
		log.Println("Web 上传页面已关闭：未设置 UPLOAD_ADMIN_TOKEN")
	case len(uploadAdminToken) < 8:
		log.Println("警告：UPLOAD_ADMIN_TOKEN 短于 8 字节，建议改用更长的随机值")
	default:
		log.Println("Web 上传页面已开启：GET /uploadbooks")
	}
}

// UploadAdminEnabled 返回上传页面是否开放（即是否配置了 token）。
func UploadAdminEnabled() bool { return uploadAdminToken != "" }

func uploadTokenMatches(provided string) bool {
	if uploadAdminToken == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(provided)), []byte(uploadAdminToken)) == 1
}

// UploadAdminAuth 校验 X-Upload-Token 请求头；未开放或 token 不符时中断请求。
func UploadAdminAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !UploadAdminEnabled() {
			c.AbortWithStatusJSON(http.StatusNotFound, gin.H{"error": "上传页面未开放"})
			return
		}
		token := c.GetHeader("X-Upload-Token")
		if token == "" {
			token = c.PostForm("token")
		}
		if !uploadTokenMatches(token) {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "token 无效"})
			return
		}
		c.Next()
	}
}

// UploadAdminPage 返回上传页面的静态 HTML；未开放时返回 404。
func UploadAdminPage(c *gin.Context) {
	if !UploadAdminEnabled() {
		c.String(http.StatusNotFound, "上传页面未开放")
		return
	}
	c.Header("Content-Type", "text/html; charset=utf-8")
	c.String(http.StatusOK, uploadBooksPageHTML)
}

// UploadAdminVerifyToken 供页面在进入前校验 token 有效性。
func UploadAdminVerifyToken(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// adminNode 文件浏览器返回的条目。
type adminNode struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	IsDir     bool   `json:"is_dir"`
	Size      int64  `json:"size"`
	Extension string `json:"extension,omitempty"`
	IsArchive bool   `json:"is_archive"`
	Supported bool   `json:"supported"`
	ModTime   int64  `json:"mod_time"`
}

// adminResolveDir 解析目录逻辑路径为物理路径并确保是已存在目录（根目录为 NAS 书库）。
func adminResolveDir(rel string) (string, string, error) {
	norm := utils.NormalizeRelPath(rel)
	abs, err := utils.SafeResolvePath(norm)
	return abs, norm, err
}

// UploadAdminList 列出目录（根为 NAS 书库根），隐藏点号开头的项。
func UploadAdminList(c *gin.Context) {
	abs, norm, err := adminResolveDir(c.DefaultQuery("path", "/"))
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "目录不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取目录: " + err.Error()})
		return
	}

	nodes := make([]adminNode, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") { // 隐藏文件与 .trashBin 等一律不展示
			continue
		}
		info, infoErr := e.Info()
		if infoErr != nil {
			continue
		}
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
		nodes = append(nodes, adminNode{
			Name:      name,
			Path:      joinAdminPath(norm, name),
			IsDir:     e.IsDir(),
			Size:      info.Size(),
			Extension: ext,
			IsArchive: !e.IsDir() && uploadArchiveExts[ext],
			Supported: e.IsDir() || IsSupportedBookExt(ext),
			ModTime:   info.ModTime().UnixMilli(),
		})
	}

	c.JSON(http.StatusOK, gin.H{"current_path": norm, "items": nodes})
}

// UploadAdminUpload 接收多文件上传（支持目录上传：paths[] 与 files[] 一一对应）。
// 非受支持格式且非压缩包的文件会被自动过滤丢弃。
func UploadAdminUpload(c *gin.Context) {
	targetDir := c.DefaultPostForm("path", "/")
	baseAbs, _, err := adminResolveDir(targetDir)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	form, err := c.MultipartForm()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "解析上传表单失败: " + err.Error()})
		return
	}
	files := form.File["files"]
	if len(files) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "未选择任何文件"})
		return
	}
	relPaths := form.Value["paths"] // 目录上传时携带每个文件的相对路径

	saved, skipped := 0, 0
	for i, fh := range files {
		// 目录上传时用相对路径保留层级，否则退化为纯文件名
		rel := fh.Filename
		if i < len(relPaths) && strings.TrimSpace(relPaths[i]) != "" {
			rel = relPaths[i]
		}
		cleanRel := sanitizeUploadRelPath(rel)
		if cleanRel == "" {
			skipped++
			continue
		}
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(cleanRel), "."))
		if !IsSupportedBookExt(ext) && !uploadArchiveExts[ext] { // 过滤不支持的格式
			skipped++
			continue
		}
		dest := filepath.Join(baseAbs, filepath.FromSlash(cleanRel))
		if !isWithin(baseAbs, dest) { // 兜底防穿越
			skipped++
			continue
		}
		if err := saveMultipartTo(fh, dest); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败: " + err.Error()})
			return
		}
		saved++
	}

	c.JSON(http.StatusOK, gin.H{"code": 200, "message": "上传完成", "saved": saved, "skipped": skipped})
}

// UploadAdminMkdir 在指定父目录下创建子目录。
func UploadAdminMkdir(c *gin.Context) {
	var req struct {
		Path string `json:"path" binding:"required"`
		Name string `json:"name" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数无效: " + err.Error()})
		return
	}
	name := sanitizeSegment(req.Name)
	if name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "非法目录名"})
		return
	}
	target := joinAdminPath(utils.NormalizeRelPath(req.Path), name)
	abs, err := utils.SafeResolvePath(target)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建目录失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 200, "message": "已创建", "path": target})
}

// UploadAdminDelete 删除文件或目录（目录递归删除）。禁止删除书库根。
func UploadAdminDelete(c *gin.Context) {
	var req struct {
		Path string `json:"path" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数无效: " + err.Error()})
		return
	}
	norm := utils.NormalizeRelPath(req.Path)
	if norm == "/" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不允许删除书库根目录"})
		return
	}
	abs, err := utils.SafeResolvePath(norm)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	if err := os.RemoveAll(abs); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 200, "message": "已删除"})
}

// UploadAdminRename 重命名或移动文件/目录。from、to 均为逻辑路径。
func UploadAdminRename(c *gin.Context) {
	var req struct {
		From string `json:"from" binding:"required"`
		To   string `json:"to" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数无效: " + err.Error()})
		return
	}
	fromNorm := utils.NormalizeRelPath(req.From)
	toNorm := utils.NormalizeRelPath(req.To)
	if fromNorm == "/" || toNorm == "/" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不允许操作书库根目录"})
		return
	}
	srcAbs, err := utils.SafeResolvePath(fromNorm)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	dstAbs, err := utils.SafeResolvePath(toNorm)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	if _, statErr := os.Stat(dstAbs); statErr == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "目标已存在"})
		return
	}
	if err := os.MkdirAll(filepath.Dir(dstAbs), 0o755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建目标目录失败: " + err.Error()})
		return
	}
	if err := os.Rename(srcAbs, dstAbs); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "移动失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 200, "message": "已完成", "path": toNorm})
}

// UploadAdminExtract 解压 zip 压缩包到其所在目录下的同名子目录，仅提取受支持的电子书，过滤其余条目。
func UploadAdminExtract(c *gin.Context) {
	var req struct {
		Path string `json:"path" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数无效: " + err.Error()})
		return
	}
	norm := utils.NormalizeRelPath(req.Path)
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(norm), "."))
	if !uploadArchiveExts[ext] {
		c.JSON(http.StatusBadRequest, gin.H{"error": "仅支持解压 zip 压缩包"})
		return
	}
	zipAbs, err := utils.SafeResolvePath(norm)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	// 解压到 <压缩包同目录>/<去扩展名的包名>/ 下
	baseName := strings.TrimSuffix(path.Base(norm), filepath.Ext(norm))
	destDirRel := joinAdminPath(path.Dir(norm), baseName)
	destAbs, err := utils.SafeResolvePath(destDirRel)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	extracted, skipped, err := extractSupportedFromZip(zipAbs, destAbs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解压失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"code": 200, "message": "解压完成", "path": destDirRel,
		"extracted": extracted, "skipped": skipped,
	})
}

// --- 内部辅助 ---

// joinAdminPath 拼接逻辑目录与子项名，保持以 / 开头的归一化形式。
func joinAdminPath(base, name string) string {
	return path.Join("/", base, name)
}

// sanitizeSegment 校验单个路径段（目录名/文件名），拒绝分隔符、空名与隐藏名。
func sanitizeSegment(raw string) string {
	name := strings.TrimSpace(strings.ReplaceAll(raw, "\\", "/"))
	if strings.Contains(name, "/") {
		name = path.Base(name)
	}
	if name == "" || name == "." || name == ".." || strings.HasPrefix(name, ".") {
		return ""
	}
	return name
}

// sanitizeUploadRelPath 归一化上传相对路径，逐段消毒，拒绝穿越与隐藏段。
func sanitizeUploadRelPath(raw string) string {
	slashed := strings.ReplaceAll(raw, "\\", "/")
	parts := strings.Split(slashed, "/")
	clean := make([]string, 0, len(parts))
	for _, p := range parts {
		seg := sanitizeSegment(p)
		if seg == "" {
			continue
		}
		clean = append(clean, seg)
	}
	if len(clean) == 0 {
		return ""
	}
	return strings.Join(clean, "/")
}

// isWithin 判断 target 是否位于 base 目录内（含 base 自身）。
func isWithin(base, target string) bool {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return false
	}
	return rel == "." || !strings.HasPrefix(rel, "..")
}

// saveMultipartTo 将上传文件写入目标物理路径，自动建父目录，重名追加序号避免覆盖。
func saveMultipartTo(fh *multipart.FileHeader, dest string) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	dest = uniquePhysicalPath(dest)

	src, err := fh.Open()
	if err != nil {
		return err
	}
	defer src.Close()

	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, src)
	return err
}

// uniquePhysicalPath 若目标物理路径已存在，则在文件名后追加 (n) 直到不冲突。
func uniquePhysicalPath(dest string) string {
	if _, err := os.Stat(dest); os.IsNotExist(err) {
		return dest
	}
	dir := filepath.Dir(dest)
	ext := filepath.Ext(dest)
	base := strings.TrimSuffix(filepath.Base(dest), ext)
	for i := 1; ; i++ {
		candidate := filepath.Join(dir, base+"("+strconv.Itoa(i)+")"+ext)
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
	}
}

// extractSupportedFromZip 解压 zip，仅提取受支持的电子书文件，过滤目录条目与不支持格式，防 zip-slip。
func extractSupportedFromZip(zipAbs, destAbs string) (extracted, skipped int, err error) {
	r, err := zip.OpenReader(zipAbs)
	if err != nil {
		return 0, 0, err
	}
	defer r.Close()

	if err := os.MkdirAll(destAbs, 0o755); err != nil {
		return 0, 0, err
	}

	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		cleanRel := sanitizeUploadRelPath(f.Name)
		if cleanRel == "" {
			skipped++
			continue
		}
		ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(cleanRel), "."))
		if !IsSupportedBookExt(ext) { // 仅保留受支持的电子书格式
			skipped++
			continue
		}
		target := filepath.Join(destAbs, filepath.FromSlash(cleanRel))
		if !isWithin(destAbs, target) { // 防 zip-slip 穿越
			skipped++
			continue
		}
		if err := writeZipEntry(f, target); err != nil {
			return extracted, skipped, err
		}
		extracted++
	}
	return extracted, skipped, nil
}

// writeZipEntry 将单个 zip 条目写入目标物理路径，自动建父目录，重名追加序号。
func writeZipEntry(f *zip.File, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	target = uniquePhysicalPath(target)

	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()

	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, rc)
	return err
}
