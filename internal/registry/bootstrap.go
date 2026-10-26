// 本文件实现文件系统 → 登记表的 bootstrap 与 rescan（M7 服务端地基）。
//
// 设计取舍：
//   - 逐文件提交，不开长事务：DB 为单写者连接（db.go 的 SetMaxOpenConns(1)），
//     「遍历整棵树 + 一个事务」会让全部读写阻塞数秒到数分钟；逐条 Apply 的代价是
//     可能只完成一部分登记，但 Bootstrap/Rescan 设计为幂等，重跑即可补齐。
//   - 不在事务内做文件 IO 或哈希：内容哈希（git blob）在遍历时算好，随后随事件传入。
//   - 只登记普通文件：`.git` 与任何以 '.' 开头的**目录**整棵跳过，任何以 '.' 开头的
//     **文件**（.gitignore / .DS_Store 等）同样跳过（版本库、工具配置与编辑器缓存
//     不是笔记内容）；符号链接与目录不登记。
package registry

import (
	"context"
	"io/fs"
	"path/filepath"
	"strings"
	"time"

	"seshat/internal/logging"
	"seshat/internal/pathguard"
	"seshat/internal/storage"
)

// rescanListLimit 是 Rescan 比对阶段一次拉取登记行的上限。
//
// storage.ListResources 没有 offset 参数，故用足够大的上限一次取全；上限过小会把
// 「未遍历到」误判为缺失，从而错误地写 delete 事件。
const rescanListLimit = 1 << 20

// Bootstrap 先 SetRoots，再遍历每个根目录把普通文件登记进 resources。
//
// 判定口径（逐文件）：
//   - 未登记 → 生成 uid 并写 create；
//   - 已登记且 Size/Mtime/Blob 均未变 → Unchanged（不产生事件，客户端游标不推进）；
//   - 已登记但有变化（含墓碑复活）→ 写 update，uid 不变。
//
// Blob 仅在 Mode=mirror 且有 repo 时计算（git blob hash）；ondemand 根（书库）
// 不在 git 仓库内，blob 恒为空串。
func (s *Service) Bootstrap(ctx context.Context, roots []Root) (Stats, error) {
	if err := s.SetRoots(roots); err != nil {
		return Stats{}, err
	}

	var st Stats
	for _, root := range roots {
		if _, err := s.scanRoot(ctx, root, &st); err != nil {
			return st, err
		}
	}
	return st, nil
}

// Rescan 先跑一遍 Bootstrap 逻辑，再把「登记中存活但本次未遍历到」的资源写墓碑，
// 用于修复写钩子漏记（进程崩溃、外部工具直接改盘等）。
//
// 墓碑记录不物理删除且仍占用 (root, path)：文件重新出现时按 update 复活原 uid，
// 因此 Rescan 不会让同一路径产生第二个 uid。
//
// 补充：点路径（.git 与以 '.' 开头的文件/目录）不再被扫描，故登记表里历史遗留的
// 点路径行会被本次 Rescan 写成墓碑（并产生 delete 事件）——即使该文件仍躺在磁盘上。
// 这类行的清理走 tombstoneLegacy（原因见该函数说明）。
func (s *Service) Rescan(ctx context.Context, roots []Root) (Stats, error) {
	if err := s.SetRoots(roots); err != nil {
		return Stats{}, err
	}

	var st Stats
	for _, root := range roots {
		seen, err := s.scanRoot(ctx, root, &st)
		if err != nil {
			return st, err
		}

		items, err := s.db.ListResources(storage.ResourceFilter{
			Root:  strings.TrimSpace(root.Tag),
			Limit: rescanListLimit,
		})
		if err != nil {
			return st, err
		}
		for _, item := range items {
			if _, ok := seen[item.Path]; ok {
				continue
			}
			if err := s.deleteMissing(item); err != nil {
				st.Failed++
				continue
			}
			st.Deleted++
		}
	}
	return st, nil
}

// deleteMissing 为「登记中存活、但本次扫描未遍历到」的资源写墓碑与 delete 事件。
//
// 两条路径：
//   - 路径仍被规则接受（normalizeResourcePath 通过）→ 走 Apply（与写钩子同一套语义，
//     含 uid 校验、op 归一与单事务落库）；
//   - 路径已不被接受（点路径等历史遗留行）→ 走 Apply 必然失败：Apply 对**所有** op 都
//     先调用 normalizeResourcePath（见 service.go），点路径会被判 invalid_argument，
//     于是每轮 Rescan 只会计一次 Failed、墓碑永远写不下去——这正是本次要消除的
//     「稳定噪音」。故这类行走 tombstoneLegacy 直接落库。
func (s *Service) deleteMissing(item storage.Entry) error {
	if _, err := normalizeResourcePath(item.Path); err == nil {
		_, err = s.Apply(Event{
			UID:  item.UID,
			Op:   storage.OpDelete,
			Root: item.Root,
			Path: item.Path,
		})
		return err
	}
	return s.tombstoneLegacy(item)
}

// tombstoneLegacy 为「路径已不再被接受」的登记行写墓碑与 delete 事件。
//
// 语义与 Apply 的 delete 分支一致（墓碑保留删除前的 root/path，只改 deleted_at 与
// updated_at；事件携带该行当前的 blob/rev），区别只在于跳过 normalizeResourcePath——
// 该行的 path 本身就是历史数据，规范化只会得到一个与之一致的字符串，对清理无意义。
// 复用 storage.ApplyResourceChange，使「登记 + 事件」仍在同一事务内落库。
func (s *Service) tombstoneLegacy(item storage.Entry) error {
	at := time.Now().UTC().Format(time.RFC3339)
	entry := item
	entry.DeletedAt = at
	entry.UpdatedAt = at
	_, err := s.db.ApplyResourceChange(entry, storage.Change{
		UID:       item.UID,
		Op:        storage.OpDelete,
		Root:      item.Root,
		Path:      item.Path,
		Blob:      item.Blob,
		Rev:       item.Rev,
		ChangedAt: at,
	})
	return err
}

// isDotName 判断单个目录项名字是否为点路径（.git 或任何以 '.' 开头的名字）。
//
// 规则本体在 internal/pathguard（单一真源）；本包装保留在此是为了让调用点与既有
// 用例继续按这个名字断言。
//
// WalkDir 是逐层回调的，点目录整棵被 SkipDir 剪掉，因此「逐项检查名字」等价于
// 「检查路径的全部段」（与 service.go 的 normalizeResourcePath 同口径）。
func isDotName(name string) bool {
	return pathguard.IsDotName(name)
}

// scanRoot 遍历单个根目录并逐文件登记，返回本次实际遍历到的相对路径集合。
//
// 返回值语义：集合成员是「本次扫描确认磁盘上仍存在」的路径——只要目录项来自成功的
// WalkDir 回调、且 d.Info() 与 rel 计算成功即写入，与随后读元数据 / 查登记表 / Apply
// 是否成功无关。原因是 Rescan 用该集合判定「登记中存活但磁盘上已不存在」：若把
// 「文件存在但登记失败」的路径排除在外，Rescan 会为它写墓碑并产生 delete 事件，把一次
// 可重试的写入失败放大成客户端可见的「文件被删除」。失败只计入 Stats.Failed，
// 由下一次 Bootstrap / Rescan 重试补齐（两者均幂等）。
//
// 点路径（.git 与以 '.' 开头的目录/文件）不计入 seen：它们本来就不该登记，因此
// 登记表里若残留旧的点路径行，Rescan 会按「磁盘上已不存在（就登记而言）」写墓碑，
// 把历史数据清理干净。
func (s *Service) scanRoot(ctx context.Context, root Root, st *Stats) (map[string]struct{}, error) {
	seen := make(map[string]struct{})

	base := strings.TrimSpace(root.Path)
	if base == "" {
		return seen, logging.NewAppError(logging.ErrInvalidArgument,
			"根 "+root.Tag+" 的物理路径不能为空")
	}
	base = filepath.Clean(base)
	mirror := strings.TrimSpace(root.Mode) == RootModeMirror

	walkErr := filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}

		if err != nil {
			if p == base {
				// 根目录本身不可读：整体失败，不静默当成「空根」。
				return logging.Wrap(err, logging.ErrInvalidArgument, "读取根目录失败")
			}
			if d != nil && d.IsDir() {
				st.Failed++
				return fs.SkipDir
			}
			st.Failed++
			return nil
		}

		if d.IsDir() {
			if p == base {
				return nil
			}
			if isDotName(d.Name()) {
				return fs.SkipDir
			}
			return nil
		}

		// 点文件与点目录同口径跳过（见 isDotName）。
		//
		// 必要性：normalizeResourcePath 拒绝任何点路径，若把 .gitignore 之类放行到登记
		// 流程，Apply 必然失败——每轮 Bootstrap/Rescan 都记一次 Failed（「稳定噪音」），
		// 且永远不会成功登记。跳过它既消除噪音，也保持「扫描可见集」与「登记可接受集」
		// 一致。
		if isDotName(d.Name()) {
			return nil
		}

		// 只登记普通文件：符号链接、设备、管道等一律跳过（不跟随链接，避免越界与重复）。
		if !d.Type().IsRegular() {
			return nil
		}

		info, infoErr := d.Info()
		if infoErr != nil {
			st.Failed++
			return nil
		}
		rel, relErr := filepath.Rel(base, p)
		if relErr != nil {
			st.Failed++
			return nil
		}
		rel = filepath.ToSlash(rel)
		mtime := info.ModTime().Unix()
		st.Scanned++

		// 磁盘上确认存在即计入 seen：后续登记失败只让本次统计 Failed++，
		// 不得让 Rescan 把该文件当成「已从磁盘消失」而写墓碑（见 scanRoot 注释）。
		seen[rel] = struct{}{}

		blob := ""
		if mirror && s.repo != nil {
			// 哈希在事务外计算（见文件头「不在事务内做文件 IO」）。
			if h, hashErr := s.repo.BlobHash(rel); hashErr == nil {
				blob = h
			}
		}

		event := Event{
			Root:  root.Tag,
			Path:  rel,
			Blob:  blob,
			Size:  info.Size(),
			Mtime: mtime,
		}

		existing, getErr := s.db.GetResourceByPath(root.Tag, rel)
		switch {
		case getErr != nil && isNotFound(getErr):
			uid, uidErr := NewUID()
			if uidErr != nil {
				st.Failed++
				return nil
			}
			event.UID, event.Op = uid, storage.OpCreate
		case getErr != nil:
			st.Failed++
			return nil
		case existing.DeletedAt != "" ||
			existing.Size != info.Size() ||
			existing.Mtime != mtime ||
			existing.Blob != blob:
			event.UID, event.Op = existing.UID, storage.OpUpdate
		default:
			st.Unchanged++
			return nil
		}

		if _, applyErr := s.applyEvent(event); applyErr != nil {
			st.Failed++
			return nil
		}
		if event.Op == storage.OpCreate {
			st.Created++
		} else {
			st.Updated++
		}
		return nil
	})
	if walkErr != nil {
		return seen, walkErr
	}
	return seen, nil
}
