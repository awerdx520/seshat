// Package attach 提供二进制附件的内容寻址存储（M1.5）。
//
// 设计要点：
//   - 内容寻址：以附件内容的 SHA256（十六进制）作为对象名，天然去重，相同内容
//     只存一份；
//   - 分片目录：对象存于 root/<hash 前两位>/<hash>，避免单目录文件过多；
//   - 原子写入：先写同目录临时文件再 rename，避免半写文件被当作有效对象；
//   - 元数据入库：hash→路径映射存 SQLite 的 attachments 表（见 storage 迁移 v3）；
//   - 清单入 git：WriteManifest 把 attachments 表内容导出到笔记目录内的清单文件，
//     随 WebDAV 写操作被 M1.2 自动 commit，从而让二进制附件不进 git 也能被追溯。
//
// 注意：对象库 root 应位于笔记目录（WebDAV 挂载根）之外，避免对象被 WebDAV 暴露
// 或被 git 跟踪；纳入 git 的只有体积极小的清单文件。
package attach

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"notes/internal/logging"
	"notes/internal/storage"
)

// ManifestFileName 是附件清单文件的文件名（位于笔记目录内）。
const ManifestFileName = ".attachments-manifest"

// timestampLayout 是附件记录时间列的存储格式，与 storage 包保持一致（RFC3339）。
const timestampLayout = time.RFC3339

// Store 是附件对象库：以 SHA256 为内容地址把二进制附件落到 root 下的分片目录，
// 并在 db 的 attachments 表中维护 hash→路径映射。
type Store struct {
	root string
	db   *storage.DB
}

// NewStore 构造对象库。root 为对象库根目录（如 ./data/files/objects），须位于笔记
// 目录之外；db 为已打开并完成迁移的存储层。
func NewStore(root string, db *storage.DB) *Store {
	return &Store{root: root, db: db}
}

// Store 写入一份附件内容并返回其 SHA256（十六进制）。
//
// 流程：计算内容哈希 → 若对象文件已存在（去重命中）则跳过写入，否则在分片目录内
// 原子写入（临时文件 + rename，权限 0644）→ 在 attachments 表 UPSERT 映射记录。
// 相同内容重复调用返回相同 hash，且对象文件只保留一份。
func (s *Store) Store(data []byte) (hash string, err error) {
	if s == nil || s.db == nil {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "附件存储未初始化")
	}

	sum := sha256.Sum256(data)
	hash = hex.EncodeToString(sum[:])
	objPath := s.objectPath(hash)

	// 去重：对象已存在则跳过写入（相同内容必然写到同一路径）。
	exists, err := s.Exists(hash)
	if err != nil {
		return "", err
	}
	if !exists {
		if err := writeFileAtomic(objPath, data, 0o644); err != nil {
			return "", err
		}
	}

	// UPSERT：hash 为主键，冲突时仅刷新 path/size，保留首次入库的 created_at。
	createdAt := time.Now().UTC().Format(timestampLayout)
	_, err = s.db.SQL().Exec(
		`INSERT INTO attachments(hash, path, size, created_at) VALUES(?, ?, ?, ?)
		 ON CONFLICT(hash) DO UPDATE SET path = excluded.path, size = excluded.size`,
		hash, objPath, len(data), createdAt)
	if err != nil {
		return "", logging.Wrap(err, logging.ErrInternal, "写入附件映射失败")
	}
	return hash, nil
}

// Exists 报告指定 hash 的对象文件是否存在。hash 非法（过短）时返回
// ErrInvalidArgument 包装的错误。
func (s *Store) Exists(hash string) (bool, error) {
	if err := validateHash(hash); err != nil {
		return false, err
	}

	_, err := os.Stat(s.objectPath(hash))
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, os.ErrNotExist):
		return false, nil
	default:
		return false, logging.Wrap(err, logging.ErrInternal, "检查附件对象失败")
	}
}

// GetPath 从 attachments 表读取指定 hash 的对象路径并返回。记录不存在时返回
// ErrNotFound 包装的错误，hash 非法时返回 ErrInvalidArgument。
func (s *Store) GetPath(hash string) (string, error) {
	if s == nil || s.db == nil {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "附件存储未初始化")
	}
	if err := validateHash(hash); err != nil {
		return "", err
	}

	var path string
	err := s.db.SQL().QueryRow(
		`SELECT path FROM attachments WHERE hash = ?`, hash).Scan(&path)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return "", logging.Wrap(err, logging.ErrNotFound, "附件不存在")
	case err != nil:
		return "", logging.Wrap(err, logging.ErrInternal, "读取附件映射失败")
	}
	return path, nil
}

// WriteManifest 把 attachments 表的全部记录导出为清单文件 dir/.attachments-manifest。
//
// 清单为 UTF-8 文本，每行一条记录，格式为「hash<两空格>path<两空格>size」，按 hash
// 升序排列，便于 diff 与 git 追溯。dir 为笔记目录（WebDAV 挂载根），因此清单会随
// 笔记目录内的写操作被自动纳入 git。文件以原子方式写入（临时文件 + rename）。
func WriteManifest(dir string, db *storage.DB) error {
	if strings.TrimSpace(dir) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "清单目录不能为空")
	}
	if db == nil || db.SQL() == nil {
		return logging.NewAppError(logging.ErrInvalidArgument, "附件清单数据库未初始化")
	}

	rows, err := db.SQL().Query(`SELECT hash, path, size FROM attachments ORDER BY hash`)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取附件清单失败")
	}
	defer func() { _ = rows.Close() }()

	var buf strings.Builder
	for rows.Next() {
		var hash, path string
		var size int64
		if err := rows.Scan(&hash, &path, &size); err != nil {
			return logging.Wrap(err, logging.ErrInternal, "解析附件记录失败")
		}
		fmt.Fprintf(&buf, "%s  %s  %d\n", hash, path, size)
	}
	if err := rows.Err(); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "遍历附件记录失败")
	}

	if err := writeFileAtomic(filepath.Join(dir, ManifestFileName), []byte(buf.String()), 0o644); err != nil {
		return err
	}
	return nil
}

// objectPath 返回对象在对象库中的完整路径：root/<hash 前两位>/<hash>。
func (s *Store) objectPath(hash string) string {
	return filepath.Join(s.root, hash[:2], hash)
}

// validateHash 校验 hash 至少含两位字符（分片目录需要前两位），否则返回
// ErrInvalidArgument 包装的错误。
func validateHash(hash string) error {
	if len(hash) < 2 {
		return logging.NewAppError(logging.ErrInvalidArgument, "附件 hash 非法")
	}
	return nil
}

// writeFileAtomic 以原子方式把 data 写入 path：先在同目录创建临时文件，写满并
// chmod 后再 rename 覆盖目标。同目录 rename 在 POSIX 下是原子操作，可避免读者看到
// 半写文件；失败时清理临时文件。
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "创建目录失败")
	}

	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "创建临时文件失败")
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return logging.Wrap(err, logging.ErrInternal, "写入临时文件失败")
	}
	// os.CreateTemp 默认权限 0600，按目标权限收敛。
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		cleanup()
		return logging.Wrap(err, logging.ErrInternal, "设置文件权限失败")
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return logging.Wrap(err, logging.ErrInternal, "关闭临时文件失败")
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return logging.Wrap(err, logging.ErrInternal, "提交文件失败")
	}
	return nil
}
