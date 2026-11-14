// utils/bookname.go
package utils

import (
	"path/filepath"
	"regexp"
	"strings"
)

// 书名归一化用的尾部剥离模式，按顺序在循环中反复尝试，直到文件名不再变化。
// 目的：让“我的同年1-99.txt”与“我的同年1-120.txt”归一化后同为“我的同年”，
// 从而在书籍内容更新（指纹变化）后仍能按名称匹配上新旧文件。
var trailingStripPatterns = []*regexp.Regexp{
	// 尾部括号区间：(1-99) / 【1～99】 / （1至99）
	regexp.MustCompile(`[\(\[\{（【]\s*\d+\s*[-~～－—–至]\s*\d+\s*[\)\]\}）】]$`),
	// 尾部数字区间：1-99 / 1～99 / 1至99
	regexp.MustCompile(`\d+\s*[-~～－—–至]\s*\d+$`),
	// 尾部章节序号：第99章 / 第12回 / 卷3 等
	regexp.MustCompile(`第?\s*\d+\s*[章回节集卷部话篇]$`),
	// 尾部括号组（任意内容）：(精校版) / 【全本】 等
	regexp.MustCompile(`[\(\[\{（【][^\(\[\{（【\)\]\}）】]*[\)\]\}）】]$`),
	// 尾部纯数字：卷一之后的阿拉伯数字序号
	regexp.MustCompile(`\d+$`),
	// 尾部分隔符与空白：- _ ～ · 。 、 以及中英文标点
	regexp.MustCompile(`[\s\-_－—–~·.。、,，;；:：!！?？'""「」]+$`),
}

// NormalizeBookName 把电子书文件名归一化为“核心书名”，用于书籍更新前后的相似名匹配：
// 小写化 → 去扩展名 → 循环剥离尾部的章节区间、括号组、序号与分隔符。
// 剥离结果为空时退化为“去扩展名后的原名”，避免所有无名文件互相误匹配。
func NormalizeBookName(fileName string) string {
	name := strings.ToLower(strings.TrimSpace(fileName))

	// 去扩展名（无扩展名或以点开头如 ".git" 风格的隐藏名时保留原样）
	if ext := filepath.Ext(name); ext != "" && len(ext) <= len(name) && strings.TrimPrefix(ext, ".") != "" {
		stem := strings.TrimSuffix(name, ext)
		if stem != "" {
			name = stem
		}
	}

	for {
		trimmed := name
		for _, re := range trailingStripPatterns {
			trimmed = strings.TrimSpace(re.ReplaceAllString(trimmed, ""))
		}
		if trimmed == name || trimmed == "" {
			break
		}
		name = trimmed
	}

	if name == "" {
		// 全部被剥掉（如纯数字文件名 "1.txt"），退回去扩展名的原名
		fallback := strings.ToLower(strings.TrimSpace(fileName))
		if ext := filepath.Ext(fallback); ext != "" {
			if stem := strings.TrimSuffix(fallback, ext); stem != "" {
				fallback = stem
			}
		}
		return fallback
	}
	return name
}
