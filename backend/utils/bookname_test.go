// utils/bookname_test.go
package utils

import "testing"

func TestNormalizeBookName(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		// 核心场景：书籍更新前后应归一化到同一核心名
		{"我的同年1-99.txt", "我的同年"},
		{"我的同年1-120.txt", "我的同年"},
		{"我的同年(1-99).txt", "我的同年"},
		{"我的同年【1～120】.txt", "我的同年"},
		{"我的同年1至99.txt", "我的同年"},
		{"我的同年 第99章.txt", "我的同年"},
		{"我的同年（精校版）.txt", "我的同年"},
		{"我的同年-精校.txt", "我的同年-精校"}, // 无括号标签不剥离，避免误伤书名本身

		// 无尾部数字的普通书名保持不变
		{"三体.txt", "三体"},
		{"三体.epub", "三体"},

		// 系列书卷号剥掉后可能撞名（由候选唯一性校验兜底，不属于归一化的职责）
		{"我的同年1.txt", "我的同年"},
		{"我的同年2.txt", "我的同年"},

		// 大小写与空白
		{"  Dune 2021.TXT ", "dune"},

		// 剥光后退化：纯数字/纯区间文件名不产生空串
		{"1-99.txt", "1-99"},
		{"123.txt", "123"},

		// 无扩展名
		{"我的同年1-99", "我的同年"},

		// 多层尾巴一次循环剥净
		{"我的同年1-99(精校版).txt", "我的同年"},
	}

	for _, tc := range cases {
		if got := NormalizeBookName(tc.name); got != tc.want {
			t.Errorf("NormalizeBookName(%q) = %q, want %q", tc.name, got, tc.want)
		}
	}
}
