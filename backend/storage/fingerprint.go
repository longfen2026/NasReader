package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
)

// fastFileFingerprint 本地后端指纹：SHA256(前4KB + 后4KB + 文件大小)，需读文件内容。
func fastFileFingerprint(filePath string, size int64) string {
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
