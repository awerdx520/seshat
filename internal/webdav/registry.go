// 本文件实现 WebDAV 写方法成功后的身份登记钩子（M7 任务 A4）：把变更登记进
// registry（resources + changes），使「路径身份」与「稳定 uid」两套视图同步。
//
// 钩子位置固定（外层 → 内层）：indexAfterWrite → registryAfterWrite →
// commitAfterWrite → newDAVHandler。而 registryAfterWrite 必须在 commitAfterWrite
// 外层（才能取到 commit 之后的 HEAD 作为 rev），并在 indexAfterWrite 内层。
//
// 登记以响应状态码为准：只有 2xx 才登记，失败的写请求不改动登记表。任何推导或
// 写入失败都只记日志，不影响已发出的响应——登记是「尽力而为」的后置动作。
package webdav

import (
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"seshat/internal/gitver"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// registryAfterWrite 包装 next：在写方法返回成功响应（2xx）后，把本次变更登记进
// registry（resources + changes）。
//
// rootTag 是逻辑根标签（如 notes，A6 传 roots[0].Tag）；prefix 为该 handler 的
// URL 前缀；offset 为挂载根相对仓库根的偏移（与 indexAfterWrite 同语义，对外出口
// 为 "public" 之类）。svc 为 nil 时不产生任何登记；repo 为 nil 时 rev 记空串、
// BlobHash 与目标 stat 跳过（blob/size/mtime 留零值）。
//
// 本函数自带 statusRecorder（与 indexAfterWrite 各自包各自），两层嵌套正常工作：
// 内层记录后转发，外层同样能读到状态码。MKCOL / PROPPATCH 不登记。
func registryAfterWrite(rootTag, prefix, offset string, svc *registry.Service, repo *gitver.Repo, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)

		if svc == nil {
			return
		}
		if rec.status < http.StatusOK || rec.status >= http.StatusMultipleChoices {
			return
		}
		applyRegistryAfterWrite(rootTag, prefix, offset, svc, repo, r)
	})
}

// firstRootTag 返回 svc 的首个根标签（默认根，与 SetRoots 的顺序一致）。
// svc 为 nil 或尚未调用 SetRoots 时返回空串——此时 registryAfterWrite 会跳过
// 登记并记日志，而不是猜测根名。
func firstRootTag(svc *registry.Service) string {
	if svc == nil {
		return ""
	}
	roots := svc.Roots()
	if len(roots) == 0 {
		return ""
	}
	return roots[0].Tag
}

// applyRegistryAfterWrite 按请求方法推导并应用登记事件。仅在 2xx 之后调用
// （此时落盘与 commit 均已完成）。
func applyRegistryAfterWrite(rootTag, prefix, offset string, svc *registry.Service, repo *gitver.Repo, r *http.Request) {
	if strings.TrimSpace(rootTag) == "" {
		log.Printf("webdav: %s %s 后登记事件失败: 逻辑根标签为空（是否未调用 SetRoots）",
			strings.ToUpper(r.Method), r.URL.Path)
		return
	}

	// repoPath 把请求路径（或 MOVE/COPY 的 Destination 头）换算为仓库内相对路径：
	// 先剥掉 handler 前缀得到挂载根相对路径，再叠加 offset。返回空串表示无法解析。
	repoPath := func(raw string) string {
		rel := indexRelPath(prefix, raw)
		if rel == "" {
			return ""
		}
		return path.Join(offset, rel)
	}

	rev := headRev(repo)

	switch strings.ToUpper(r.Method) {
	case http.MethodPut:
		applyPut(rootTag, repoPath(r.URL.Path), svc, repo, rev)
	case http.MethodDelete:
		applyDelete(rootTag, repoPath(r.URL.Path), svc)
	case "MOVE":
		applyMove(rootTag, repoPath(r.URL.Path), repoPath(r.Header.Get("Destination")), svc, rev)
	case "COPY":
		applyCopy(rootTag, repoPath(r.Header.Get("Destination")), svc, repo, rev)
	}
}

// headRev 返回仓库当前 HEAD（尽力而为）：repo 为 nil、空仓库或读取失败时返回空串。
func headRev(repo *gitver.Repo) string {
	if repo == nil {
		return ""
	}
	head, err := repo.Head()
	if err != nil {
		log.Printf("webdav: 读取 HEAD 失败，rev 记空串: %v", err)
		return ""
	}
	return head
}

// applyPut 登记一次 PUT：新建路径生成新 uid 并记 create；已有存活登记记 update
// （uid 不变）。
//
// 已墓碑资源被覆盖（先删后又写入同一路径）时复用墓碑行的 uid 并发 OpUpdate：
// registry.Apply 会把「update 但资源不存活」归一为 create 并清除墓碑，既避免
// UNIQUE(root, path) 冲突，也让「路径复活的资源」保持同一身份（墓碑行的 path
// 仍占用该路径，另生成新 uid 会撞唯一约束）。
func applyPut(rootTag, repoPath string, svc *registry.Service, repo *gitver.Repo, rev string) {
	if repoPath == "" {
		log.Printf("webdav: PUT 后登记失败: 无法从请求路径解析仓库内相对路径")
		return
	}

	blob, size, mtime := statMeta(repo, repoPath)
	uid, op, err := resolvePutTarget(svc, rootTag, repoPath)
	if err != nil {
		log.Printf("webdav: PUT %s 后解析登记目标失败: %v", repoPath, err)
		return
	}

	if _, err := svc.Apply(registry.Event{
		UID:   uid,
		Op:    op,
		Root:  rootTag,
		Path:  repoPath,
		Blob:  blob,
		Rev:   rev,
		Size:  size,
		Mtime: mtime,
	}); err != nil {
		log.Printf("webdav: PUT %s 后登记事件失败: %v", repoPath, err)
		return
	}
	refreshRefsAfterWrite(svc, rootTag, repoPath)
}

// resolvePutTarget 决定 PUT 事件的目标 uid 与 op：
//
//   - 路径已登记且存活 → 同一 uid + OpUpdate；
//   - 路径只有墓碑记录 → 复用墓碑 uid + OpUpdate（由 registry.Apply 复活）；
//   - 完全未登记 → 新 uid + OpCreate。
//
// 快路径用 ResolvePath（唯一索引命中）；墓碑不会被它返回，故 miss 后按
// (root, prefix) 列举登记（含墓碑）再按精确 path 收敛——ListResources 的 Prefix
// 是 LIKE 段前缀匹配，可能因路径含 % / _ 而多命中，必须精确比较。
func resolvePutTarget(svc *registry.Service, rootTag, repoPath string) (string, string, error) {
	if uid, err := svc.ResolvePath(rootTag, repoPath); err == nil {
		return uid, storage.OpUpdate, nil
	}

	items, err := svc.List(storage.ResourceFilter{
		Root:           rootTag,
		Prefix:         repoPath,
		IncludeDeleted: true,
		// Limit 显式给足：Prefix 是 LIKE 段前缀匹配，路径含 % / _ 时可能多命中
		// 无关行；而 UNIQUE(root, path) 保证精确匹配最多一行，故取足够大的上限
		// 即可避免「被截断而漏掉墓碑行」后另生成新 uid 撞唯一约束。
		Limit: 1000,
	})
	if err != nil {
		return "", "", err
	}
	for _, item := range items {
		if item.Path == repoPath {
			return item.UID, storage.OpUpdate, nil
		}
	}

	uid, err := registry.NewUID()
	if err != nil {
		return "", "", err
	}
	return uid, storage.OpCreate, nil
}

// applyDelete 登记一次 DELETE：对目标路径下所有存活登记写墓碑并追加 delete 事件。
//
// 目标可能是文件也可能是目录：ListResources 的 Prefix 语义为「自身或子树」，故单
// 文件情形只命中自身，目录情形命中整棵子树；已墓碑的行跳过（不重复记事件）。
func applyDelete(rootTag, repoPath string, svc *registry.Service) {
	if repoPath == "" {
		log.Printf("webdav: DELETE 后登记失败: 无法从请求路径解析仓库内相对路径")
		return
	}

	items, err := svc.List(storage.ResourceFilter{Root: rootTag, Prefix: repoPath})
	if err != nil {
		log.Printf("webdav: DELETE %s 后列举登记失败: %v", repoPath, err)
		return
	}
	for _, item := range items {
		if item.DeletedAt != "" {
			continue
		}
		if !inSubtree(item.Path, repoPath) {
			// Prefix 是 LIKE 匹配（含 % / _ 的路径可能多命中），此处再按路径段边界收敛，
			// 避免把无关资源误写墓碑。
			continue
		}
		if _, err := svc.Apply(registry.Event{
			UID:  item.UID,
			Op:   storage.OpDelete,
			Root: rootTag,
			Path: item.Path,
		}); err != nil {
			log.Printf("webdav: DELETE %s 后登记 %s 删除事件失败: %v", repoPath, item.Path, err)
			continue
		}
		// 已删除的源不再有引用：清空其出边，避免引用图残留指向已删文档的旧链接。
		if err := svc.ClearRefs(item.UID); err != nil {
			log.Printf("webdav: DELETE %s 后清空 %s 的引用失败: %v", repoPath, item.UID, err)
		}
	}
}

// refreshRefsAfterWrite 在 .org 写成功后刷新该源文件的引用图（失败只记日志）。
//
// 只对 .org 触发：其它扩展名不含 seshat: 链接，且 RefreshRefs 对非 .org 会清空
// 引用——若对所有写都调用，附件覆盖会无谓地读写 refs 表。
func refreshRefsAfterWrite(svc *registry.Service, rootTag, repoPath string) {
	if !strings.HasSuffix(strings.ToLower(repoPath), ".org") {
		return
	}
	if err := svc.RefreshRefs(rootTag, repoPath); err != nil {
		log.Printf("webdav: 刷新 %s 的引用失败: %v", repoPath, err)
	}
}

// inSubtree 报告 p 是否等于 root 或位于其子树内（按路径段边界判断，
// 故 inSubtree("ab", "a") 为 false）。
func inSubtree(p, root string) bool {
	return p == root || strings.HasPrefix(p, root+"/")
}

// applyMove 登记一次 MOVE：源为文件或目录时，对该前缀下所有存活登记发 rename
// 事件，uid 保持不变。
//
// 路径换算：suffix = TrimPrefix(登记路径, 源路径)，新路径 = 目标路径 + suffix。
// 单文件情形 suffix 为空串，新路径即目标路径；目录情形保留各自的相对层级。
func applyMove(rootTag, srcPath, dstPath string, svc *registry.Service, rev string) {
	if srcPath == "" || dstPath == "" {
		log.Printf("webdav: MOVE 后登记失败: 无法解析源或目标路径（src=%q dst=%q）", srcPath, dstPath)
		return
	}

	items, err := svc.List(storage.ResourceFilter{Root: rootTag, Prefix: srcPath})
	if err != nil {
		log.Printf("webdav: MOVE %s 后列举登记失败: %v", srcPath, err)
		return
	}
	for _, item := range items {
		if !inSubtree(item.Path, srcPath) {
			// 同 applyDelete：LIKE 前缀可能多命中，按路径段边界收敛后再计算 suffix。
			continue
		}
		suffix := strings.TrimPrefix(item.Path, srcPath)
		newPath := dstPath + suffix
		if _, err := svc.Apply(registry.Event{
			UID:     item.UID,
			Op:      storage.OpRename,
			Root:    rootTag,
			Path:    newPath,
			OldPath: item.Path,
			Rev:     rev,
		}); err != nil {
			log.Printf("webdav: MOVE 后登记 %s → %s 改名事件失败: %v", item.Path, newPath, err)
			continue
		}
	}
	// 注意：Move 后源文件已不存在，故不能用 statMeta 刷新内容元数据；rename 事件的
	// Blob/Size/Mtime 留空/零值，registry.Apply 对空值不覆盖既有登记。
}

// applyCopy 登记一次 COPY：目标侧一律生成新 uid 并记 create。
//
// 目标是文件时登记单个资源；是目录时遍历其下所有普通文件（跳过以 "." 开头的
// 目录，与「不登记 .git 与隐藏目录」的约定一致）逐个登记。遍历依赖仓库工作区
// 的实际落盘结果——COPY 已完成，故目标内容可 stat。
func applyCopy(rootTag, dstPath string, svc *registry.Service, repo *gitver.Repo, rev string) {
	if dstPath == "" {
		log.Printf("webdav: COPY 后登记失败: 无法从 Destination 头解析仓库内相对路径")
		return
	}
	if repo == nil {
		log.Printf("webdav: COPY %s 后登记失败: 未提供 git 仓库，无法定位工作区文件", dstPath)
		return
	}

	full := filepath.Join(repo.Root(), filepath.FromSlash(dstPath))
	info, err := os.Stat(full)
	if err != nil {
		log.Printf("webdav: COPY 后 stat %s 失败: %v", dstPath, err)
		return
	}
	if !info.IsDir() {
		applyCopyFile(rootTag, dstPath, svc, repo, rev)
		return
	}

	if err := filepath.WalkDir(full, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			// 目标根自身放行；其下以 "." 开头的目录整棵跳过。
			if p != full && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		rel, relErr := filepath.Rel(repo.Root(), p)
		if relErr != nil {
			return relErr
		}
		applyCopyFile(rootTag, filepath.ToSlash(rel), svc, repo, rev)
		return nil
	}); err != nil {
		log.Printf("webdav: COPY %s 后遍历目标目录失败: %v", dstPath, err)
	}
}

// applyCopyFile 为单个被复制的文件登记新身份（新 uid + create 事件）。
//
// COPY 复制的是内容而非身份：目标文件是独立实体，必须拥有独立 uid，否则两份
// 内容会共用一条登记（路径不断被覆盖）。
//
// 登记成功后刷新该目标的引用图（仅 .org，复用 refreshRefsAfterWrite 与 PUT 同语义，
// 失败只记日志）：复制出的 .org 里可能含 seshat: 链接，这些出边必须挂在新 uid 上；
// 源文件的 refs 与登记均不受影响。目录 COPY 由 applyCopy 的遍历循环逐个调用本函数，
// 故两处共用同一逻辑，无需另走一遍 WalkDir。
func applyCopyFile(rootTag, repoPath string, svc *registry.Service, repo *gitver.Repo, rev string) {
	uid, err := registry.NewUID()
	if err != nil {
		log.Printf("webdav: COPY 后为 %s 生成 uid 失败: %v", repoPath, err)
		return
	}

	blob, size, mtime := statMeta(repo, repoPath)
	if _, err := svc.Apply(registry.Event{
		UID:   uid,
		Op:    storage.OpCreate,
		Root:  rootTag,
		Path:  repoPath,
		Blob:  blob,
		Rev:   rev,
		Size:  size,
		Mtime: mtime,
	}); err != nil {
		log.Printf("webdav: COPY 后登记 %s 失败: %v", repoPath, err)
		return
	}
	refreshRefsAfterWrite(svc, rootTag, repoPath)
}

// statMeta 返回仓库内相对路径 repoPath 对应文件的内容元数据：git blob hash、
// 字节数与 mtime（Unix 秒）。repo 为 nil、文件不可读或非普通文件时对应值留空/零，
// 失败只记日志。
//
// 路径以仓库工作区根为基准（含 offset），故对外出口的子目录文件同样能取到哈希。
func statMeta(repo *gitver.Repo, repoPath string) (blob string, size, mtime int64) {
	if repo == nil {
		return "", 0, 0
	}

	hash, err := repo.BlobHash(repoPath)
	if err != nil {
		log.Printf("webdav: 计算 %s 的 blob hash 失败: %v", repoPath, err)
	} else {
		blob = hash
	}

	info, err := os.Stat(filepath.Join(repo.Root(), filepath.FromSlash(repoPath)))
	if err != nil {
		log.Printf("webdav: stat %s 失败: %v", repoPath, err)
		return blob, 0, 0
	}
	return blob, info.Size(), info.ModTime().Unix()
}
