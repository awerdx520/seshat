package attach

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"notes/internal/storage"
)

// openTestDB 在临时目录打开一个全新的测试库，并注册测试结束后的清理。
func openTestDB(t *testing.T) *storage.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "notes.db")
	db, err := storage.Open(path, "")
	if err != nil {
		t.Fatalf("storage.Open() 返回错误: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// countFiles 递归统计 dir 下的普通文件数量。
func countFiles(t *testing.T, dir string) int {
	t.Helper()
	count := 0
	err := filepath.WalkDir(dir, func(_ string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			count++
		}
		return nil
	})
	if err != nil {
		t.Fatalf("遍历 %s 失败: %v", dir, err)
	}
	return count
}

// objectPathOf 按分片规则构造期望的对象路径，供测试断言使用。
func objectPathOf(root, hash string) string {
	return filepath.Join(root, hash[:2], hash)
}

// TestStoreDeduplicates 验证相同内容两次写入返回同一 hash，且对象文件只写一份。
func TestStoreDeduplicates(t *testing.T) {
	db := openTestDB(t)
	root := filepath.Join(t.TempDir(), "objects")
	s := NewStore(root, db)

	data := []byte("二进制附件内容：同一份电子书")

	h1, err := s.Store(data)
	if err != nil {
		t.Fatalf("首次 Store() 返回错误: %v", err)
	}
	h2, err := s.Store(data)
	if err != nil {
		t.Fatalf("二次 Store() 返回错误: %v", err)
	}
	if h1 != h2 {
		t.Fatalf("相同内容应返回相同 hash: %q != %q", h1, h2)
	}
	if len(h1) != 64 {
		t.Fatalf("hash 长度 = %d, 期望 64（SHA256 hex）", len(h1))
	}
	if _, err := hex.DecodeString(h1); err != nil {
		t.Fatalf("hash 不是合法的十六进制串: %v", err)
	}

	got, err := os.ReadFile(objectPathOf(root, h1))
	if err != nil {
		t.Fatalf("读取对象文件失败: %v", err)
	}
	if string(got) != string(data) {
		t.Fatalf("对象内容 = %q, 期望 %q", got, data)
	}
	if n := countFiles(t, root); n != 1 {
		t.Fatalf("对象库文件数 = %d, 期望 1（去重后只存一份）", n)
	}
}

// TestStoreDistinctContent 验证不同内容得到不同 hash，且各自落盘。
func TestStoreDistinctContent(t *testing.T) {
	db := openTestDB(t)
	root := filepath.Join(t.TempDir(), "objects")
	s := NewStore(root, db)

	h1, err := s.Store([]byte("内容甲"))
	if err != nil {
		t.Fatalf("Store(甲) 返回错误: %v", err)
	}
	h2, err := s.Store([]byte("内容乙"))
	if err != nil {
		t.Fatalf("Store(乙) 返回错误: %v", err)
	}
	if h1 == h2 {
		t.Fatalf("不同内容不应返回相同 hash: %q", h1)
	}
	if n := countFiles(t, root); n != 2 {
		t.Fatalf("对象库文件数 = %d, 期望 2", n)
	}
}

// TestExistsAndGetPath 验证 Exists 与 GetPath 的行为。
func TestExistsAndGetPath(t *testing.T) {
	db := openTestDB(t)
	root := filepath.Join(t.TempDir(), "objects")
	s := NewStore(root, db)

	hash, err := s.Store([]byte("附件数据"))
	if err != nil {
		t.Fatalf("Store() 返回错误: %v", err)
	}

	ok, err := s.Exists(hash)
	if err != nil {
		t.Fatalf("Exists() 返回错误: %v", err)
	}
	if !ok {
		t.Fatalf("Exists(%s) = false, 期望 true", hash)
	}

	unknown := strings.Repeat("0", 64)
	ok, err = s.Exists(unknown)
	if err != nil {
		t.Fatalf("Exists(未知) 返回错误: %v", err)
	}
	if ok {
		t.Fatal("Exists(未知) = true, 期望 false")
	}

	got, err := s.GetPath(hash)
	if err != nil {
		t.Fatalf("GetPath() 返回错误: %v", err)
	}
	if want := objectPathOf(root, hash); got != want {
		t.Fatalf("GetPath() = %q, 期望 %q", got, want)
	}

	if _, err := s.GetPath(unknown); err == nil {
		t.Fatal("GetPath(未知) 应返回错误，实际返回 nil")
	}
}

// TestStoreRejectsShortHash 验证 Exists/GetPath 对非法 hash 返回错误而非越界。
func TestStoreRejectsShortHash(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(filepath.Join(t.TempDir(), "objects"), db)

	if _, err := s.Exists("a"); err == nil {
		t.Fatal("Exists(过短 hash) 应返回错误，实际返回 nil")
	}
	if _, err := s.GetPath(""); err == nil {
		t.Fatal("GetPath(空 hash) 应返回错误，实际返回 nil")
	}
}

// TestWriteManifest 验证清单文件生成且内容正确（按 hash 升序、格式为「hash  path  size」）。
func TestWriteManifest(t *testing.T) {
	db := openTestDB(t)
	root := filepath.Join(t.TempDir(), "objects")
	s := NewStore(root, db)

	alpha := []byte("alpha")
	beta := []byte("beta")
	hAlpha, err := s.Store(alpha)
	if err != nil {
		t.Fatalf("Store(alpha) 返回错误: %v", err)
	}
	hBeta, err := s.Store(beta)
	if err != nil {
		t.Fatalf("Store(beta) 返回错误: %v", err)
	}

	dir := filepath.Join(t.TempDir(), "notes-root")
	if err := WriteManifest(dir, db); err != nil {
		t.Fatalf("WriteManifest() 返回错误: %v", err)
	}

	raw, err := os.ReadFile(filepath.Join(dir, ManifestFileName))
	if err != nil {
		t.Fatalf("读取清单文件失败: %v", err)
	}
	text := string(raw)
	if !strings.HasSuffix(text, "\n") {
		t.Fatalf("清单应以换行结尾，实际 %q", text)
	}

	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("清单行数 = %d, 期望 2；内容:\n%s", len(lines), text)
	}

	type entry struct {
		hash string
		path string
		size int
	}
	want := []entry{
		{hash: hAlpha, path: objectPathOf(root, hAlpha), size: len(alpha)},
		{hash: hBeta, path: objectPathOf(root, hBeta), size: len(beta)},
	}
	sort.Slice(want, func(i, j int) bool { return want[i].hash < want[j].hash })

	for i, e := range want {
		fields := strings.Split(lines[i], "  ")
		if len(fields) != 3 {
			t.Fatalf("第 %d 行格式非法（期望 3 段）: %q", i+1, lines[i])
		}
		if fields[0] != e.hash {
			t.Fatalf("第 %d 行 hash = %q, 期望 %q", i+1, fields[0], e.hash)
		}
		if fields[1] != e.path {
			t.Fatalf("第 %d 行 path = %q, 期望 %q", i+1, fields[1], e.path)
		}
		if fields[2] != strconv.Itoa(e.size) {
			t.Fatalf("第 %d 行 size = %q, 期望 %d", i+1, fields[2], e.size)
		}
	}
}

// TestWriteManifestEmpty 验证无附件时仍生成空清单文件（幂等，便于 git 追踪「清空」）。
func TestWriteManifestEmpty(t *testing.T) {
	db := openTestDB(t)
	dir := filepath.Join(t.TempDir(), "notes-root")
	if err := WriteManifest(dir, db); err != nil {
		t.Fatalf("WriteManifest() 返回错误: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, ManifestFileName))
	if err != nil {
		t.Fatalf("读取清单文件失败: %v", err)
	}
	if len(raw) != 0 {
		t.Fatalf("空库清单应为空文件，实际 %q", raw)
	}
}
