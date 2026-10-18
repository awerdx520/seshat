// Package storage 提供笔记系统的 SQLite 持久化层：打开数据库、执行 schema
// 迁移与关闭连接。
//
// 驱动选择：本包通过 build tag 支持双驱动，Open 的调用方接口在两种构建下保持一致：
//
//   - 默认构建（无 tag）：使用纯 Go 驱动 modernc.org/sqlite（无需 CGO），驱动名
//     为 "sqlite"，不支持 DB 层加密，Open 的非空 key 被忽略并告警。
//   - `-tags sqlcipher` 构建：使用 github.com/mutecomm/go-sqlcipher/v4（CGO，包内
//     自带 SQLCipher amalgamation，无需系统 libsqlcipher），驱动名为 "sqlite3"，
//     Open 的非空 key 经 PRAGMA key 启用 DB 层加密。因 schema 迁移 v4 依赖 FTS5
//     虚表、而该驱动默认未编入 FTS5，加密构建须同时加 fts5 tag，即
//     `-tags "sqlcipher sqlite_fts5"`。
//
// 驱动导入与 DSN 构造分别位于 driver_modernc.go 与 driver_sqlcipher.go，本文件
// 仅保留与驱动无关的公共逻辑（Open/Close/迁移）。
package storage

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"seshat/internal/logging"
)

// schemaVersion 是当前程序期望的 schema 版本号。
//
// 语义：migrations 中第 i 条脚本将 user_version 从 i 迁移到 i+1，因此
// schemaVersion 必须恒等于 len(migrations)（由 TestMigrationsLengthMatchesVersion 守卫）。
// 新增迁移时：追加脚本到 migrations 末尾，并把 schemaVersion 加一。
const schemaVersion = 7

// migrations 按版本顺序保存 schema 迁移脚本。
//
// 约束：新增迁移只能追加到末尾、不得修改已发布的脚本；脚本本身建议写成可重复
// 执行的形式（如 CREATE TABLE IF NOT EXISTS），以便在版本号写入失败重试时保持幂等。
var migrations = []string{
	// v1：元数据表，用于存放系统级键值对；后续里程碑在此基础上扩展其它表。
	`CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
)`,
	// v2：阅读进度与批注表（M1.4 REST 状态同步的数据基础）。
	//
	// reading_progress 以 document_id 为主键，即每个文档只保留最新进度（后写覆盖）；
	// annotations 单条一行，按 document_id 建索引以支撑「按文档列举」这一主要查询。
	// updated_at/created_at 为 RFC3339 文本，由调用方（服务端或客户端）提供的
	// 时间戳决定，便于与客户端协商增量同步。
	`CREATE TABLE IF NOT EXISTS reading_progress (
	document_id TEXT PRIMARY KEY,
	position    TEXT NOT NULL,
	updated_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS annotations (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	document_id TEXT NOT NULL,
	location    TEXT NOT NULL,
	text        TEXT NOT NULL,
	created_at  TEXT NOT NULL,
	updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_annotations_document ON annotations(document_id);`,
	// v3：附件内容寻址表（M1.5）。
	//
	// hash 为附件内容的 SHA256 十六进制串，既是主键也是对象库中的文件名；path 为
	// 对象在对象库中的完整路径（root/前两位/hash 分片）；size 为字节数；created_at
	// 为首次入库时的 RFC3339（UTC）时间。该表是「附件清单」文件的数据来源，清单
	// 随笔记目录内的写操作纳入 git 追踪。
	`CREATE TABLE IF NOT EXISTS attachments (
    hash TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    created_at TEXT NOT NULL
);`,
	// v4：全文索引虚表（M1.6）。
	//
	// 用 FTS5 虚表承载笔记正文的全文索引，由纯 Go 驱动 modernc.org/sqlite 提供
	// FTS5 扩展支持。path 列标为 UNINDEXED：只随结果回填、用于定位文件，不参与
	// 分词；content 列为被索引的正文。增量更新策略为「按 path 先删后插」，封装于
	// internal/index 包，使同一文件的索引始终反映最新内容。
	`CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    path UNINDEXED,
    content
);`,
	// v5：LLM 任务队列表（M6.2 本地处理节点 worker）。
	//
	// 混合 LLM 后端的任务分发基础：需要本地推理的任务以 route='local' 入队，由
	// 家庭机器 / NAS 上的处理节点轮询领取（status: pending → running → done/failed）；
	// route='cloud' 的任务由服务端直接调云端 API，不进入节点轮询。payload 为任务
	// 请求体的原始 JSON 文本（对队列透明，由任务类型与节点共同解释）；result 承载
	// 节点的结果正文，或失败时的错误信息（明文存储，无端到端加密）。
	`CREATE TABLE IF NOT EXISTS llm_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    route TEXT NOT NULL,
    status TEXT NOT NULL,
    result TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);`,
	// v6：文件身份三表（M7 服务端地基：uid 身份 · 引用 · 增量同步）。
	//
	// 本版本只新增身份相关表，不改动任何既有表——「身份登记」（v6）与「状态表按 uid
	// 重建」（v7，B4 落地）分开，使两者各自成为可独立验证的交付点。
	//
	// resources 是服务端权威的文件身份登记：uid 由服务端生成，跨改名稳定；path 为
	// 当前路径，UNIQUE(root, path) 保证同一根下一条路径只对应一个 uid；删除写墓碑
	// （deleted_at 置非空）而非物理删除，path 保留删除前值，使按 uid 仍可追溯。
	// blob 建索引以支撑「按内容哈希找资源」的反查。
	//
	// changes 是全局单调游标日志：seq 由 SQLite AUTOINCREMENT 提供，保证严格递增且
	// 不复用（客户端以最后消费的 seq 作游标拉增量）；op 取值 create/update/rename/delete；
	// old_path 仅 rename 事件使用。日志不设 TTL。
	//
	// refs 是引用图：一条记录表示「source 在 source_location 处引用了 target」；
	// 复合主键天然去重，target_uid 建索引以支撑「谁引用了我」的反向查询。
	`-- 资源登记表：服务端权威文件身份
CREATE TABLE IF NOT EXISTS resources (
  uid        TEXT PRIMARY KEY,
  root       TEXT NOT NULL,
  path       TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'file',
  blob       TEXT NOT NULL DEFAULT '',
  size       INTEGER NOT NULL DEFAULT 0,
  mtime      INTEGER NOT NULL DEFAULT 0,
  rev        TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE(root, path)
);
CREATE INDEX IF NOT EXISTS idx_resources_blob ON resources(blob);

-- 变更日志：全局单调游标
CREATE TABLE IF NOT EXISTS changes (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  uid        TEXT NOT NULL,
  op         TEXT NOT NULL,
  root       TEXT NOT NULL,
  path       TEXT NOT NULL,
  old_path   TEXT NOT NULL DEFAULT '',
  blob       TEXT NOT NULL DEFAULT '',
  rev        TEXT NOT NULL DEFAULT '',
  changed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_changes_uid ON changes(uid);

-- 引用图
CREATE TABLE IF NOT EXISTS refs (
  source_uid      TEXT NOT NULL,
  source_location TEXT NOT NULL DEFAULT '',
  target_uid      TEXT NOT NULL,
  target_location TEXT NOT NULL DEFAULT '',
  created_at      TEXT NOT NULL,
  PRIMARY KEY (source_uid, source_location, target_uid, target_location)
);
CREATE INDEX IF NOT EXISTS idx_refs_target ON refs(target_uid);`,
	// v7：状态表按 uid 重建（M7 B4：状态 API 破坏性切换）。
	//
	// 为什么 DROP 重建而非数据搬迁：M7 开工时服务端尚未部署，状态表无存量数据；
	// 保留 document_id 需长期维护两套读写路径，收益为零。该假设不靠约定兜底——执行
	// 本脚本前由 preMigrationChecks[7] 机械校验两表为空，非空即中止（见
	// assertStateTablesEmptyBeforeRebuild）。
	//
	// 重建后的语义与 v2 一致，只把文档键从 document_id（路径/内容标识）换成 uid
	// （服务端权威身份，跨改名稳定）：reading_progress 仍以文档键为主键（每文档一条、
	// 后写覆盖），annotations 仍按文档键建索引以支撑「按文档列举」。
	`DROP TABLE IF EXISTS reading_progress;
CREATE TABLE IF NOT EXISTS reading_progress (
  uid        TEXT PRIMARY KEY,
  position   TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
DROP TABLE IF EXISTS annotations;
CREATE TABLE IF NOT EXISTS annotations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uid        TEXT NOT NULL,
  location   TEXT NOT NULL,
  text       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_annotations_uid ON annotations(uid);`,
}

// errEmptyPath 表示调用方传入了空的数据库路径。
var errEmptyPath = errors.New("数据库路径为空")

// preMigrationChecks 保存「脚本执行之前」必须通过的防御性检查（键为迁移版本号）。
//
// 存在理由：v7 会 DROP 并重建状态表，这是不可逆操作；计划假设 H7「状态表无存量
// 数据」必须由机械校验兜住，而不是靠部署约定。检查必须在脚本执行前、同一事务内
// 运行，失败即整体回滚（user_version 保持原值）。
//
// 为什么用独立 map 而不在 applyMigration 内写 version == 7 分支：applyMigration 是
// 通用函数，若为一处需求塞入特定版本分支，后续每次不可逆迁移都要再加一条分支；
// 用钩子表则「预防性检查」与「迁移逻辑」解耦，新增版本只需追加一条记录，其余版本
// 语义完全不变（无钩子的版本走空检查，行为与改动前一致）。
var preMigrationChecks = map[int]func(tx *sql.Tx) error{
	7: assertStateTablesEmptyBeforeRebuild,
}

// assertStateTablesEmptyBeforeRebuild 是 v7 的前置检查：reading_progress 与
// annotations 都必须为空，任一非空则拒绝重建（避免静默丢数据）。
//
// 表不存在时视为 0 行（全新库或从未写过状态）——存在性经 sqlite_master 判断，
// 因为对缺表执行 SELECT COUNT(*) 会报错而非返回 0。错误信息同时给出两表行数，
// 让运维一眼看出是哪张表有数据。
func assertStateTablesEmptyBeforeRebuild(tx *sql.Tx) error {
	progressRows, err := countRowsIfExists(tx, "reading_progress")
	if err != nil {
		return err
	}
	annotationRows, err := countRowsIfExists(tx, "annotations")
	if err != nil {
		return err
	}
	if progressRows == 0 && annotationRows == 0 {
		return nil
	}
	return logging.Wrap(
		fmt.Errorf("状态表非空，拒绝执行 v7 重建（reading_progress=%d, annotations=%d）",
			progressRows, annotationRows),
		logging.ErrInternal, "迁移中止")
}

// countRowsIfExists 返回表的行数；表不存在时返回 0。
func countRowsIfExists(tx *sql.Tx, table string) (int64, error) {
	var exists int
	err := tx.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&exists)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "检查表 "+table+" 是否存在失败")
	}
	if exists == 0 {
		return 0, nil
	}

	// 表名来自包内常量列表，不经用户输入，直接拼接安全（PRAGMA/表名无法参数化）。
	var rows int64
	if err := tx.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&rows); err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "统计表 "+table+" 行数失败")
	}
	return rows, nil
}

// DB 封装底层 SQLite 连接，并暴露存储层的打开/关闭能力。
type DB struct {
	db   *sql.DB
	path string
}

// Open 打开（或创建）位于 path 的 SQLite 数据库，并自动执行尚未应用的 schema 迁移。
//
// key 为数据库加密密钥，其语义随构建而定：默认构建不启用 DB 层加密，非空 key 被
// 忽略并告警；`-tags sqlcipher` 构建下非空 key 通过 PRAGMA key 启用加密，空 key
// 则以明文打开并告警（见 warnKeyMode 与 buildDSN 的驱动实现）。该参数在两种构建下
// 保持同一签名，调用方无需为是否加密而改动。
func Open(path, key string) (*DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, logging.Wrap(errEmptyPath, logging.ErrInvalidArgument, "打开数据库失败")
	}

	warnKeyMode(path, key)

	db, err := sql.Open(driverName(), buildDSN(path, key))
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "打开数据库失败")
	}

	// SQLite 为单写者模型：限制为单连接可避免并发写导致的 SQLITE_BUSY 竞争，
	// 代价是读并发受限；后续如需更高读并发可改用读写分离的连接池。
	db.SetMaxOpenConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, logging.Wrap(err, logging.ErrInternal, "连接数据库失败")
	}

	if err := applyMigrations(db); err != nil {
		_ = db.Close()
		return nil, err
	}

	return &DB{db: db, path: path}, nil
}

// Close 关闭底层数据库连接并释放资源；对 nil 接收者安全。
func (d *DB) Close() error {
	if d == nil || d.db == nil {
		return nil
	}
	return d.db.Close()
}

// SQL 返回底层 *sql.DB，供 storage 包外的模块（如 internal/attach 附件对象库）
// 直接执行对应表的 SQL；对 nil 接收者返回 nil。
//
// 设计说明：storage 包内的领域读写（进度、批注等）仍封装为包内方法；此访问器
// 仅供尚无专门领域方法、且以「表即简单键值映射」为主的场景使用，避免为每张表都
// 新增一层薄封装。连接池已被限制为单连接（见 Open），调用方无需额外串行化。
func (d *DB) SQL() *sql.DB {
	if d == nil {
		return nil
	}
	return d.db
}

// applyMigrations 读取当前 user_version，并按序执行所有未应用的迁移。
func applyMigrations(db *sql.DB) error {
	var current int
	if err := db.QueryRow("PRAGMA user_version").Scan(&current); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取 schema 版本失败")
	}

	if current > schemaVersion {
		return logging.Wrap(
			fmt.Errorf("数据库 schema 版本 %d 高于程序支持的 %d", current, schemaVersion),
			logging.ErrInternal, "数据库版本不兼容")
	}

	for v := current; v < schemaVersion; v++ {
		if err := applyMigration(db, v+1); err != nil {
			return err
		}
	}
	return nil
}

// applyMigration 在单个事务内执行一条迁移脚本并推进 user_version，保证二者原子生效。
func applyMigration(db *sql.DB, version int) error {
	tx, err := db.Begin()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("开始迁移 v%d 事务失败", version))
	}
	defer func() { _ = tx.Rollback() }()

	// 不可逆迁移的前置防御（见 preMigrationChecks）：在脚本执行之前完成，失败即
	// 回滚，user_version 保持原值——「迁移要么整体生效，要么库完全没变」。
	if check := preMigrationChecks[version]; check != nil {
		if err := check(tx); err != nil {
			return err
		}
	}

	if _, err := tx.Exec(migrations[version-1]); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("应用迁移 v%d 失败", version))
	}

	// PRAGMA 不支持参数占位符；version 为包内递增常量，直接拼接安全。
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", version)); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("更新 schema 版本至 v%d 失败", version))
	}

	if err := tx.Commit(); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("提交迁移 v%d 失败", version))
	}
	return nil
}
