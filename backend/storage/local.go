package storage

import (
	"io"
	"os"
	"path"
	"path/filepath"
	"reader-sync/utils"
)

// localBackend 用本地文件系统实现 Backend，行为与改造前完全一致。
// 逻辑路径到物理路径的映射复用 utils 中既有的安全解析逻辑。
type localBackend struct{}

func newLocalBackend() *localBackend { return &localBackend{} }

// resolve 把逻辑相对路径解析为物理绝对路径（自动区分 NAS 书库与上传目录两个根）。
func (b *localBackend) resolve(relPath string) (string, error) {
	abs, _, err := utils.ResolveLibraryPath(relPath)
	return abs, err
}

func (b *localBackend) ReadDir(relPath string) ([]FileInfo, error) {
	dir, err := b.resolve(relPath)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	base := utils.NormalizeRelPath(relPath)
	out := make([]FileInfo, 0, len(entries))
	for _, e := range entries {
		info, infoErr := e.Info()
		if infoErr != nil {
			continue
		}
		out = append(out, FileInfo{
			Name:    e.Name(),
			Path:    joinLogical(base, e.Name()),
			IsDir:   e.IsDir(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		})
	}
	return out, nil
}

func (b *localBackend) Stat(relPath string) (FileInfo, error) {
	abs, err := b.resolve(relPath)
	if err != nil {
		return FileInfo{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return FileInfo{}, err
	}
	return FileInfo{
		Name:    info.Name(),
		Path:    utils.NormalizeRelPath(relPath),
		IsDir:   info.IsDir(),
		Size:    info.Size(),
		ModTime: info.ModTime(),
	}, nil
}

func (b *localBackend) Exists(relPath string) (bool, error) {
	abs, err := b.resolve(relPath)
	if err != nil {
		return false, err
	}
	if _, err := os.Stat(abs); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (b *localBackend) Open(relPath string) (io.ReadCloser, FileInfo, error) {
	abs, err := b.resolve(relPath)
	if err != nil {
		return nil, FileInfo{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, FileInfo{}, err
	}
	f, err := os.Open(abs)
	if err != nil {
		return nil, FileInfo{}, err
	}
	return f, FileInfo{
		Name:    info.Name(),
		Path:    utils.NormalizeRelPath(relPath),
		IsDir:   info.IsDir(),
		Size:    info.Size(),
		ModTime: info.ModTime(),
	}, nil
}

func (b *localBackend) Create(relPath string, r io.Reader) error {
	abs, err := b.resolve(relPath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(abs, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		os.Remove(abs)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(abs)
		return err
	}
	return nil
}

func (b *localBackend) Rename(oldRel, newRel string) error {
	src, err := b.resolve(oldRel)
	if err != nil {
		return err
	}
	dst, err := b.resolve(newRel)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	// 跨设备（EXDEV）退化为复制后删除
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(dst)
		return err
	}
	return os.Remove(src)
}

func (b *localBackend) Remove(relPath string) error {
	abs, err := b.resolve(relPath)
	if err != nil {
		return err
	}
	return os.Remove(abs)
}

func (b *localBackend) MkdirAll(relPath string) error {
	abs, err := b.resolve(relPath)
	if err != nil {
		return err
	}
	return os.MkdirAll(abs, 0o755)
}

func (b *localBackend) Walk(relRoot string, fn WalkFunc) error {
	root, err := b.resolve(relRoot)
	if err != nil {
		return err
	}
	base := utils.NormalizeRelPath(relRoot)
	return filepath.WalkDir(root, func(fullPath string, d os.DirEntry, entryErr error) error {
		if entryErr != nil {
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			return nil
		}
		rel, relErr := filepath.Rel(root, fullPath)
		if relErr != nil {
			return nil
		}
		logical := base
		if rel != "." {
			logical = joinLogical(base, filepath.ToSlash(rel))
		}
		callErr := fn(FileInfo{
			Name:    d.Name(),
			Path:    logical,
			IsDir:   d.IsDir(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		})
		if callErr == ErrSkipSubtree {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		return callErr
	})
}

func (b *localBackend) Fingerprint(relPath string, size int64) string {
	abs, err := b.resolve(relPath)
	if err != nil {
		return ""
	}
	return fastFileFingerprint(abs, size)
}

// joinLogical 拼接逻辑目录与子项名，保持以 / 开头的归一化形式。
// 使用 slash 语义的 path 包（而非 filepath），避免 Windows 上把前导 // 误判为 UNC 路径。
func joinLogical(base, name string) string {
	joined := path.Join("/", base, name)
	return joined
}
