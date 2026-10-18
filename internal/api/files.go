// 本文件实现 M7 B3 的文件内容端点：GET /api/files/{path...}（读内容 + Range）、
// PUT /api/files/{path...}（条件写）、DELETE /api/files/{path...}（删除文件/目录）
// 与 POST /api/resources/{uid}/move（按 uid 移动，body 携带目标路径）。
//
// 三条不变量（与 WebDAV 出口共用同一个 registry，构成「双出口同一身份」）：
//
//  1. 只有 mirror 根（roots[0]，笔记根）可写。书库根按需读取、不进 git、不在 WebDAV
//     暴露，对它的写请求返回 403 root_read_only——那不是「暂时没权限」，而是架构上
//     不该写，客户端应据此回退为只读展示。
//  2. 顺序固定为「落盘 → commit → registry」：先 WriteAndCommit / RenameAndCommit /
//     RemoveAndCommit（落盘与提交在同一持锁临界区内完成），再 registry.Apply 写身份
//     与变更日志。registry 失败时文件已落盘（返回 500，由 bootstrap/rescan 补登记）；
//     反过来「先登记后落盘」会留下指向不存在文件的登记行，更难修复。
//  3. 路径先经 cleanRelPath 规范化（去前导 '/'、折叠重复斜杠、拒绝 ".."、NUL、
//     .git 段与任何以 '.' 开头的段），再经 physicalPathChecked 与根的物理路径拼接
//     并校验符号链接：父目录链**逐级 Lstat 均不得是符号链接**（含指向根内的软链与
//     悬空软链），目标自身也不得是符号链接。故任何请求都无法越出根目录，无法借
//     符号链接读写根外文件，也不会出现「两个逻辑路径指向同一物理实体」的别名。
//
// 错误码：etag_mismatch（412，条件写前提不成立）与 root_read_only（403）在
// internal/logging 定义，由 server.go 的 statusForCode 映射为 HTTP 状态码。
package api

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"seshat/internal/gitver"
	"seshat/internal/logging"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

const (
	// maxFileBytes 是 PUT 请求体的字节上限（32 MiB）。与状态端点的 1 MiB 分开：
	// 笔记根承载 org 与附件，32 MiB 足够覆盖常见附件，同时挡住无界读入内存。
	maxFileBytes = 32 << 20

	// defaultContentType 是扩展名无法推断时的 Content-Type。
	defaultContentType = "application/octet-stream"

	// deleteListLimit 是删除目录时一次列举登记行的上限（防止超大目录树无界读表）。
	// 取远大于 API 清单分页上限（2000）的值：这里必须尽量一次拿全，否则会漏写墓碑。
	deleteListLimit = 100000
)

// fileWriteResponse 是 PUT 成功的响应体。
//
// created 标记本次是否新建（201）或覆盖（200）；etag 是写入后内容的 git blob hash，
// 客户端可直接用它作为下次 PUT 的 If-Match；rev 是提交后的 HEAD，seq 是变更事件游标。
type fileWriteResponse struct {
	UID     string `json:"uid"`
	Root    string `json:"root"`
	Path    string `json:"path"`
	Blob    string `json:"blob"`
	ETag    string `json:"etag"`
	Rev     string `json:"rev"`
	Seq     int64  `json:"seq"`
	Created bool   `json:"created"`
}

// fileDeleteResponse 是 DELETE 成功的响应体。
//
// uids 是本次写了墓碑的全部 uid（文件时长度为 1，目录时为其下所有存活资源）；
// uid 在单资源删除时等于 uids[0]，目录删除时为空串（此时只有 uids 有意义）。
type fileDeleteResponse struct {
	UID  string   `json:"uid"`
	UIDs []string `json:"uids"`
	Root string   `json:"root"`
	Path string   `json:"path"`
	Seq  int64    `json:"seq"`
}

// moveRequest 是移动请求体：to 为目标路径（相对同一个根，不允许 ".." 逃逸）。
type moveRequest struct {
	To string `json:"to"`
}

// moveResponse 是移动成功的响应体：uid 不变，from/to 为根内逻辑路径。
type moveResponse struct {
	UID  string `json:"uid"`
	Root string `json:"root"`
	From string `json:"from"`
	To   string `json:"to"`
	Seq  int64  `json:"seq"`
}

// handleGetFile 返回根内文件的内容（GET /api/files/{path...}）。
//
// 查询参数 root 选择根（缺省 roots[0]）；读操作对所有根开放（书库根按需下载）。
// 响应头：ETag（内容 blob hash，带引号）、Content-Type（按扩展名推断）、
// Accept-Ranges: bytes、Last-Modified。
//
// 响应体走 http.ServeContent 流式发送（不把整个文件读进内存，书库大文件不会打爆堆）：
// Range（206 + Content-Range、不可满足的 416 + "bytes */<size>"）、If-None-Match /
// If-Modified-Since（304）、If-Range 等条件请求语义都由它按 HTTP 规范处理，本包不再
// 手写。ETag 仍按内容计算（与 PUT 返回的 etag 恒等），但改为逐块哈希：内存占用 O(1)。
func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}
	rel, err := cleanRelPath(r.PathValue("path"))
	if err != nil {
		writeError(w, err)
		return
	}
	root, err := s.selectRoot(r.URL.Query().Get("root"), false)
	if err != nil {
		writeError(w, err)
		return
	}

	physical, err := physicalPathChecked(root, rel)
	if err != nil {
		if errors.Is(err, errSymlinkPath) {
			// 读侧把「符号链接」按 404 报：对客户端而言该路径不存在可读内容，
			// 也不能据此探测根外文件是否存在（写侧才用 400 明示拒绝）。
			writeError(w, logging.NewAppError(logging.ErrNotFound, "文件不存在"))
			return
		}
		writeError(w, err)
		return
	}

	f, err := os.Open(physical)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			writeError(w, logging.NewAppError(logging.ErrNotFound, "文件不存在"))
			return
		}
		writeError(w, logging.Wrap(err, logging.ErrInternal, "打开文件失败"))
		return
	}
	defer func() { _ = f.Close() }()

	info, err := f.Stat()
	if err != nil {
		writeError(w, logging.Wrap(err, logging.ErrInternal, "读取文件状态失败"))
		return
	}
	if info.IsDir() {
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"目标是目录，不能用文件端点读取"))
		return
	}

	etag, err := fileETag(f, info.Size())
	if err != nil {
		writeError(w, logging.Wrap(err, logging.ErrInternal, "计算文件 ETag 失败"))
		return
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		writeError(w, logging.Wrap(err, logging.ErrInternal, "定位文件读取位置失败"))
		return
	}

	header := w.Header()
	header.Set("ETag", `"`+etag+`"`)
	header.Set("Accept-Ranges", "bytes")
	// nosniff 对所有下载一律设置：即便类型被降级为 octet-stream，也要明确禁止
	// 浏览器自行嗅探（旧版 IE/Edge 会忽略 octet-stream 并嗅探内容）。
	header.Set("X-Content-Type-Options", "nosniff")
	if isActiveContent(rel) {
		// 主动内容（HTML/SVG/XML/JS 等）强制降级为下载：这些类型与服务端同源，
		// 浏览器内联渲染即执行其中的脚本 → 一次 PUT 附件就能形成存储型 XSS。
		// 必须同时给 Content-Disposition: attachment，否则降级 Content-Type 只是
		// 依赖浏览器「不嗅探」的约定，直接导航仍可能按扩展名渲染。
		header.Set("Content-Type", defaultContentType)
		header.Set("Content-Disposition", contentDispositionFor(rel))
	} else {
		header.Set("Content-Type", contentTypeFor(rel))
	}

	// ServeContent 负责条件请求与 Range：ETag/Content-Type 必须在调用前设好，
	// 它读取已设的 ETag 做 If-None-Match/If-Range 判定，且不会覆盖已设的 Content-Type。
	http.ServeContent(w, r, filepath.Base(physical), info.ModTime(), f)
}

// handlePutFile 写入根内文件（PUT /api/files/{path...}，仅 mirror 根）。
//
// 条件写语义（与 HTTP 条件请求一致；If-Match 与 If-None-Match 同时出现时**两者
// 都校验**，任一不满足即 412）：
//   - 无 If-Match / If-None-Match：无条件写入（不存在则创建，存在则覆盖）；
//   - If-None-Match: *：仅允许创建，目标已存在返回 412。「存在」的判据是
//     「登记表有存活资源 **或** 磁盘上有该文件」（任一为真）；
//   - If-Match: "<blob>" / *：仅当当前内容匹配才写入，不匹配（或不存在）返回 412，
//     且内容保持不变；显式空 ETag（`If-Match: ""`）不会退化为无条件写。
//
// 落盘与提交走 gitver.WriteAndCommitIf：条件比较、写文件、提交在同一个持锁临界区内
// 完成，因此不存在「校验通过 → 内容被并发改掉 → 覆盖掉别人的写入」的时间窗；并发
// 两个相同 If-Match 的 PUT 恰好一个成功、另一个 412。
//
// 成功返回 201（新建）或 200（覆盖）+ {uid, root, path, blob, etag, rev, seq, created}。
func (s *Server) handlePutFile(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}
	rel, err := cleanRelPath(r.PathValue("path"))
	if err != nil {
		writeError(w, err)
		return
	}
	root, err := s.selectRoot(r.URL.Query().Get("root"), true)
	if err != nil {
		writeError(w, err)
		return
	}
	repo, err := s.mirrorRepo(root)
	if err != nil {
		writeError(w, err)
		return
	}

	// 符号链接与根外逃逸在读取请求体之前就拒绝（写侧按 400 明示非法参数）。
	physical, err := physicalPathChecked(root, rel)
	if err != nil {
		writeError(w, err)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxFileBytes))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
				"文件内容超过 32 MiB 上限"))
			return
		}
		writeError(w, logging.Wrap(err, logging.ErrInvalidArgument, "读取请求体失败"))
		return
	}

	// 现状判定：登记表按 (root, path) 查存活资源，据此确定 uid 与事件 op。
	var uid string
	exists := false
	switch cur, resolveErr := s.registry.ResolvePath(root.Tag, rel); {
	case resolveErr == nil:
		uid, exists = cur, true
	case isRegistryNotFound(resolveErr):
		// 路径未登记：可能是全新文件，也可能是「已删除后重建」。墓碑仍占用
		// UNIQUE(root, path)，故先查同名墓碑并复用其 uid 复活——否则新建 uid 会撞
		// 唯一约束，而同名重建本应保持身份稳定（客户端缓存的 uid 仍然有效）。
		if tomb, ok := s.tombstoneAt(root.Tag, rel); ok {
			uid = tomb.UID
		} else {
			uid, err = registry.NewUID()
			if err != nil {
				writeError(w, logging.Wrap(err, logging.ErrInternal, "生成 uid 失败"))
				return
			}
		}
	default:
		writeError(w, resolveErr)
		return
	}

	// 条件写前提：磁盘维度的「当前内容」由 gitver.WriteAndCommitIf 在写入的同一
	// 临界区内复核（避免校验与写入之间的窗口被并发写入者插入），这里的 BlobHash
	// 只用于提前给出 412，以及把「刚校验过的 blob」作为期望值交给它。
	//
	// If-Match 与 If-None-Match 同时出现时**两者都校验**（不是二选一）：RFC 9110
	// 允许任意组合，只校验其一会让客户端「我要求内容匹配且要求不存在」的复合前提
	// 被静默放宽成单条件。任一不满足即 412，内容不变。
	ifMatch := strings.TrimSpace(r.Header.Get("If-Match"))
	inm := strings.TrimSpace(r.Header.Get("If-None-Match"))
	curBlob, _ := repo.BlobHash(rel)
	wantBlob, wantAbsent := "", false
	if ifMatch != "" {
		// etagMatches 对空 blob 恒为 false，故「资源不存在」与 `If-Match: ""`
		// （显式空 ETag）都被拒——后者若被当成「空期望值」会在下层退化为无条件写。
		if !etagMatches(ifMatch, curBlob) {
			writeError(w, logging.NewAppError(logging.ErrETagMismatch,
				"If-Match 与当前内容不符（或资源不存在），内容未修改"))
			return
		}
		// 把校验过的 blob 交给 WriteAndCommitIf 复核：并发下两个相同 If-Match 的
		// PUT，后到者在锁内看到内容已变 → ErrBlobMismatch，恰好一个成功。
		wantBlob = curBlob
	}
	if inm != "" {
		if inm == "*" {
			// 存在性判据 = 登记表存活 **或** 磁盘存在（任一为真即视为已存在）。
			// 「登记表只剩墓碑、磁盘已空」的重建场景两者皆假 → 允许创建并复用
			// 墓碑 uid（身份稳定，见 tombstoneAt 与 TestPutFileRecreateAfterDelete）。
			//
			// 注意：If-Match 已匹配必然意味着资源存在，故与 `If-None-Match: *`
			// 组合时这里恒为 412——这正是「两个前提不可同时成立」的正确表达。
			if exists || curBlob != "" {
				writeError(w, logging.NewAppError(logging.ErrETagMismatch,
					"目标已存在（If-None-Match 只允许创建），内容未修改"))
				return
			}
			wantAbsent = true
		} else if etagMatches(inm, curBlob) {
			writeError(w, logging.NewAppError(logging.ErrETagMismatch,
				"目标内容与 If-None-Match 列出的 ETag 相同，内容未修改"))
			return
		}
	}

	op := storage.OpUpdate
	if !exists {
		op = storage.OpCreate
	}

	// 落盘 + 提交（同一持锁临界区，条件比较也在其中复核）。
	if _, err := repo.WriteAndCommitIf(rel, string(body),
		fmt.Sprintf("api: PUT %s:%s", root.Tag, rel), wantBlob, wantAbsent); err != nil {
		if errors.Is(err, gitver.ErrBlobMismatch) {
			// 前提在锁内被推翻（并发写入者先改了内容）：语义同 If-Match 失败。
			writeError(w, logging.NewAppError(logging.ErrETagMismatch,
				"条件写前提不成立（内容已被并发修改，或目标已存在），内容未修改"))
			return
		}
		writeError(w, err)
		return
	}
	rev, _ := repo.Head()

	size, mtime := int64(len(body)), time.Now().Unix()
	if info, statErr := os.Stat(physical); statErr == nil {
		size, mtime = info.Size(), info.ModTime().Unix()
	}
	blob := contentETag(body)

	seq, err := s.registry.Apply(registry.Event{
		UID: uid, Op: op, Root: root.Tag, Path: rel,
		Blob: blob, Rev: rev, Size: size, Mtime: mtime,
	})
	if err != nil {
		// 文件已落盘并提交，登记失败属服务端问题：记录并返回错误，
		// 由启动 bootstrap / POST /api/resources/rescan 补登记。
		slog.Error("api: 写文件后登记失败", "root", root.Tag, "path", rel, "uid", uid, "error", err)
		writeError(w, err)
		return
	}

	status := http.StatusOK
	if !exists {
		status = http.StatusCreated
	}
	// 引用图维护（M7 C1）：.org 写入成功后按新内容重解析 seshat: 链接。失败只记日志，
	// 不影响已完成的写入（引用可在下次写入或 rescan 时重建）。
	refreshRefsAfterWrite(s.registry, root.Tag, rel)
	writeJSON(w, status, fileWriteResponse{
		UID: uid, Root: root.Tag, Path: rel,
		Blob: blob, ETag: blob, Rev: rev, Seq: seq, Created: !exists,
	})
}

// handleDeleteFile 删除根内文件或目录（DELETE /api/files/{path...}，仅 mirror 根）。
//
// 目录删除按路径段边界匹配登记表（path == rel 或 path 以 rel + "/" 开头），为每个
// 存活资源写墓碑；文件删除则是长度为 1 的同一条流程。响应 200 +
// {uid, uids, root, path, seq}：uid 只在单资源删除时有值，目录删除为空串。
// 路径未登记（登记表无存活资源）返回 404 unknown_uid——物理文件可能仍在磁盘上，
// 但身份不存在，客户端应重新拉取清单而不是重复删除。
func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}
	rel, err := cleanRelPath(r.PathValue("path"))
	if err != nil {
		writeError(w, err)
		return
	}
	root, err := s.selectRoot(r.URL.Query().Get("root"), true)
	if err != nil {
		writeError(w, err)
		return
	}
	repo, err := s.mirrorRepo(root)
	if err != nil {
		writeError(w, err)
		return
	}

	// 符号链接与根外逃逸一律 400：删除符号链接本身虽不会删到根外文件，但
	// 「删除一个不由本服务登记、且指向根外的条目」没有正当语义，宁可拒绝。
	if _, err := physicalPathChecked(root, rel); err != nil {
		writeError(w, err)
		return
	}

	// 先取删除前存活的资源：删除后登记行会变墓碑，届时无法再按路径前缀收集。
	entries, err := s.registry.List(storage.ResourceFilter{
		Root:   root.Tag,
		Prefix: rel,
		Limit:  deleteListLimit,
	})
	if err != nil {
		writeError(w, err)
		return
	}
	// 按路径段边界收敛子树：prefix 只是粗筛（存储层按字符串前缀匹配），若不收敛，
	// 删除 "dir" 时可能把名字共享前缀的无关资源（"dir2/a.org"）一起写墓碑。
	// 注：internal/webdav 里有一个同名私有函数，这里刻意复制而不跨包引用——两个出口
	// 不应互相依赖对方的内部实现；两处语义必须一致（按 '/' 段边界判定）。
	kept := entries[:0]
	for _, item := range entries {
		if inSubtree(item.Path, rel) {
			kept = append(kept, item)
		}
	}
	entries = kept
	if len(entries) == 0 {
		writeLookupError(w, logging.NewAppError(logging.ErrNotFound, "路径未登记"))
		return
	}

	if err := repo.RemoveAndCommit(rel, fmt.Sprintf("api: DELETE %s:%s", root.Tag, rel)); err != nil {
		writeError(w, err)
		return
	}

	uids := make([]string, 0, len(entries))
	var (
		seq      int64
		firstErr error
	)
	for i := range entries {
		applied, applyErr := s.registry.Apply(registry.Event{
			UID: entries[i].UID, Op: storage.OpDelete, Root: root.Tag, Path: entries[i].Path,
		})
		if applyErr != nil {
			slog.Error("api: 删除文件后登记墓碑失败",
				"root", root.Tag, "path", entries[i].Path, "uid", entries[i].UID, "error", applyErr)
			if firstErr == nil {
				firstErr = applyErr
			}
			continue
		}
		uids = append(uids, entries[i].UID)
		seq = applied
		// 已删除的源不再有引用：清空其出边（失败只记日志，不影响删除结果）。
		if clearErr := s.registry.ClearRefs(entries[i].UID); clearErr != nil {
			slog.Error("api: 删除文件后清空引用失败",
				"root", root.Tag, "path", entries[i].Path, "uid", entries[i].UID, "error", clearErr)
		}
	}
	if firstErr != nil {
		// 物理删除已完成，但身份未全部更新：报错让调用方知道需要重扫，
		// 而不是假装一切正常（后续 bootstrap/rescan 会补齐墓碑）。
		writeError(w, firstErr)
		return
	}

	resp := fileDeleteResponse{Root: root.Tag, Path: rel, UIDs: uids, Seq: seq}
	if len(uids) == 1 {
		resp.UID = uids[0]
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleMoveResource 按 uid 移动文件或目录（POST /api/resources/{uid}/move）。
//
// 之所以以 uid 定位、目标路径放 body：Go 1.22 的 ServeMux 不允许 {path...} 通配段
// 之后再出现字面量段（"POST /api/files/{path...}/move" 会 panic："wildcard not at
// end"），故移动端点挂在 /api/resources/{uid}/ 下。
//
// 源与目标在同一根内（目标路径相对同一根）；uid 不变，事件为 rename（old_path 记
// 原路径）。uid 属于只读根（书库）返回 403 root_read_only；目标路径被其它 uid 占用
// 返回 409 conflict。
func (s *Server) handleMoveResource(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}
	uid := r.PathValue("uid")
	if !registry.IsUID(uid) {
		writeError(w, logging.NewAppError(logging.ErrInvalidUID,
			"uid 格式非法（须为 26 位 Crockford Base32）"))
		return
	}
	entry, err := s.registry.Entry(uid)
	if err != nil {
		writeLookupError(w, err)
		return
	}

	// 只有 mirror 根可写：默认根即 mirror 根，跨根的移动不受支持（源根必须等于它）。
	root, err := s.selectRoot("", true)
	if err != nil {
		writeError(w, err)
		return
	}
	if entry.Root != root.Tag {
		writeError(w, logging.NewAppError(logging.ErrRootReadOnly,
			"资源所属根 "+entry.Root+" 只读，不能移动"))
		return
	}

	var req moveRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	to, err := cleanRelPath(req.To)
	if err != nil {
		writeError(w, err)
		return
	}
	from := entry.Path
	if to == from {
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"目标路径与当前路径相同，无需移动"))
		return
	}
	repo, err := s.mirrorRepo(root)
	if err != nil {
		writeError(w, err)
		return
	}

	// 源与目标都不允许经符号链接：源是符号链接时改名会把链接本身挪走（根内多出一个
	// 指向根外的入口），目标的父目录经符号链接指向根外时，RenameAndCommit 会把文件
	// 搬出根。两者都按 400 拒绝（写侧语义）。
	if _, err := physicalPathChecked(root, from); err != nil {
		writeError(w, err)
		return
	}
	if _, err := physicalPathChecked(root, to); err != nil {
		writeError(w, err)
		return
	}

	if err := repo.RenameAndCommit(from, to,
		fmt.Sprintf("api: MOVE %s:%s → %s", root.Tag, from, to)); err != nil {
		writeError(w, err)
		return
	}

	seq, err := s.registry.Apply(registry.Event{
		UID: uid, Op: storage.OpRename, Root: root.Tag, Path: to, OldPath: from,
	})
	if err != nil {
		slog.Error("api: 移动文件后登记失败",
			"root", root.Tag, "from", from, "to", to, "uid", uid, "error", err)
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, moveResponse{UID: uid, Root: root.Tag, From: from, To: to, Seq: seq})
}

// cleanRelPath 把请求路径规范化为根内逻辑相对路径。
//
// 规则：去首尾空白（登记表的键同样 TrimSpace，两者必须一致）、反斜杠转 '/'、
// 拒绝含 NUL 与任一 ".." 段的路径、path.Clean 折叠重复斜杠与 '.'、去掉前导 '/'；
// 结果为空或 "." 时视为非法（不允许用文件端点指向根本身）。
//
// 规范化之后再拒绝两类段（与 internal/registry/service.go 的 normalizeResourcePath
// 保持完全一致的规则——**两处必须同步修改**，否则会出现「API 能写、登记层拒绝」
// 或反过来的死角）：
//   - 任一段为 .git（大小写不敏感）：放行 .git 等于把版本库内部目录暴露给读写端点，
//     一次 PUT/DELETE 就能破坏仓库；
//   - 任一段以 '.' 开头（隐藏文件/目录）：登记层不登记点路径（bootstrap 整棵跳过），
//     若 API 接受点路径就会出现「磁盘有、登记表没有」的不一致。
func cleanRelPath(raw string) (string, error) {
	if strings.ContainsRune(raw, 0) {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "路径不能包含 NUL 字节")
	}
	slashed := filepath.ToSlash(strings.TrimSpace(raw))
	for _, seg := range strings.Split(slashed, "/") {
		if seg == ".." {
			return "", logging.NewAppError(logging.ErrInvalidArgument,
				`路径不能包含 ".."（禁止越出根目录）`)
		}
	}
	clean := strings.TrimPrefix(path.Clean("/"+slashed), "/")
	if clean == "" || clean == "." {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "路径不能为空")
	}
	for _, seg := range strings.Split(clean, "/") {
		if strings.EqualFold(seg, ".git") {
			return "", logging.NewAppError(logging.ErrInvalidArgument,
				"路径不能包含 .git 段（版本库内部目录不可经 API 访问）")
		}
		if strings.HasPrefix(seg, ".") {
			return "", logging.NewAppError(logging.ErrInvalidArgument,
				"路径不能包含以 '.' 开头的段（隐藏文件/目录不可经 API 访问）")
		}
	}
	return clean, nil
}

// selectRoot 解析 ?root= 选择的根；raw 为空时使用默认根（roots[0]）。
//
// write=true 表示本次是写操作：非 mirror 根一律返回 ErrRootReadOnly（403）。
// 找不到该 tag 返回 ErrInvalidArgument（400）——这是客户端拼写错误，不是服务端问题。
func (s *Server) selectRoot(raw string, write bool) (registry.Root, error) {
	roots := s.registry.Roots()
	if len(roots) == 0 {
		return registry.Root{}, logging.NewAppError(logging.ErrInvalidArgument,
			"服务端未配置根清单")
	}
	tag := strings.TrimSpace(raw)
	if tag == "" {
		tag = roots[0].Tag
	}
	for _, root := range roots {
		if root.Tag != tag {
			continue
		}
		if write && root.Mode != registry.RootModeMirror {
			return registry.Root{}, logging.NewAppError(logging.ErrRootReadOnly,
				"根 "+tag+" 是只读根（按需读取，不进版本库）")
		}
		return root, nil
	}
	return registry.Root{}, logging.NewAppError(logging.ErrInvalidArgument,
		"未知的根 tag: "+tag)
}

// mirrorRepo 返回作用于 root 的版本化仓库，并校验它与根的物理路径一致。
//
// 校验的必要性：gitver 的写方法接受「仓库内相对路径」，而本文件的逻辑路径是
// 「根内相对路径」——两者只有在根就是仓库根时才等价。若配置漂移导致不一致，
// 直接写入会把文件写到错误位置（甚至写到别的根里），故宁可报 500 也不静默写错。
// 错误信息只带根 tag，不回绝对路径（物理路径属服务端部署细节）。
func (s *Server) mirrorRepo(root registry.Root) (*gitver.Repo, error) {
	if s.repo == nil {
		return nil, logging.NewAppError(logging.ErrInternal,
			"版本化仓库未启用，无法写入文件")
	}
	rootPath, err := filepath.Abs(root.Path)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal,
			"解析根 "+root.Tag+" 的物理路径失败")
	}
	if filepath.Clean(rootPath) != filepath.Clean(s.repo.Root()) {
		slog.Error("api: 根物理路径与版本库根不一致，拒绝写入",
			"root", root.Tag, "root_path", rootPath, "repo_root", s.repo.Root())
		return nil, logging.NewAppError(logging.ErrInternal,
			"根 "+root.Tag+" 的物理路径与版本库根不一致，拒绝写入")
	}
	return s.repo, nil
}

// physicalPath 返回根内逻辑路径对应的物理路径（rel 已由 cleanRelPath 规范化）。
func physicalPath(root registry.Root, rel string) string {
	return filepath.Join(root.Path, filepath.FromSlash(rel))
}

// errSymlinkPath 标记「请求路径本身是符号链接」这一拒绝原因。
//
// 调用方据此分化状态码：读写语义严格（PUT/DELETE 返回 400 明示非法请求），
// 读语义按 404 处理更自然（对客户端而言该路径没有可读内容，也避免用状态码差异
// 探测根外文件是否存在）。与 AppError 用 errors.Join 组合，故 writeError 仍能
// 取到 400 那个 AppError。
var errSymlinkPath = errors.New("符号链接")

// physicalPathChecked 返回根内逻辑路径对应的物理路径，并校验它没有借符号链接
// 逃出根目录（也没有借根内软链制造「两个逻辑路径 = 同一物理实体」的别名）。
//
// 三道检查：
//  1. 父目录链逐段 Lstat：从根开始，路径上的**每一级**父目录都必须是真实目录，
//     任何一级是符号链接即拒绝（400）——包括指向根内的软链（alias -> real）。
//     理由：uid ↔ 物理路径必须一一对应；若允许根内软链，同一实体会有两个逻辑
//     路径，登记表却只认其中一个，删除/移动/引用图都会出现「改了一个、另一个
//     还在」的幽灵条目。悬空软链在此一并覆盖（Lstat 对悬空链同样成功且模式为
//     symlink）→ 400，而不是让后续 open 抛 ENOENT 变成 500。
//  2. 兜底：父目录链的真实路径（EvalSymlinks）必须仍在根的真实路径之内。逐段
//     Lstat 已覆盖已知逃逸形态，这一条用于防御「检查与使用之间目录被替换」等
//     未预期情形。父目录允许尚不存在（PUT 会自动建目录），此时按「最深存在祖先
//     的真实路径 + 未存在的尾段」计算——尾段不含 ".."，拼接不会引入新的逃逸。
//  3. 目标自身若是符号链接则拒绝（Lstat 判定，不跟随）：否则 GET 会读到根外内容、
//     PUT 会把根外文件改掉（os.WriteFile 跟随链接）。
//
// 返回的路径未经 EvalSymlinks 改写（写侧需要能创建尚不存在的父目录）。
func physicalPathChecked(root registry.Root, rel string) (string, error) {
	p := physicalPath(root, rel)

	if err := rejectSymlinkAncestors(root, rel); err != nil {
		return "", err
	}

	base := filepath.Clean(root.Path)
	if resolved, err := filepath.EvalSymlinks(base); err == nil {
		// 根自身常是符号链接（部署侧挂载目录的常见形态），比较基准也要解析一次，
		// 否则合法路径会被误判为逃逸。
		base = resolved
	}

	realDir, err := realPathLoosely(filepath.Dir(p))
	if err != nil {
		return "", logging.Wrap(err, logging.ErrInternal, "解析路径的父目录失败")
	}
	if realDir != base && !strings.HasPrefix(realDir, base+string(filepath.Separator)) {
		return "", logging.NewAppError(logging.ErrInvalidArgument,
			"路径越出根目录（父目录经符号链接指向根外）")
	}

	if info, lstatErr := os.Lstat(p); lstatErr == nil && info.Mode()&os.ModeSymlink != 0 {
		return "", errors.Join(errSymlinkPath, logging.NewAppError(
			logging.ErrInvalidArgument, "目标路径是符号链接，拒绝跟随"))
	}
	return p, nil
}

// rejectSymlinkAncestors 逐段 Lstat 校验 rel 的父目录链，任何一级是符号链接即 400。
//
// 从根（root.Path）起逐级拼接并 Lstat，因此根自身是符号链接不受影响（检查从根的
// 下一级开始），而根内任意深度的软链都会被拦下。三种结果：
//   - 某级不存在 → 放行（PUT 会自动建目录；其后各级必然也不存在，无需继续）；
//   - 某级是符号链接 → 400（悬空软链同样命中，故「悬空软链父目录」也是 400 而非 500）；
//   - 某级存在但不是目录 → 400（路径中间出现普通文件，后续操作必然失败）。
func rejectSymlinkAncestors(root registry.Root, rel string) error {
	parent := path.Dir(rel)
	if parent == "." || parent == "/" || parent == "" {
		return nil
	}
	dir := filepath.Clean(root.Path)
	for _, seg := range strings.Split(parent, "/") {
		if seg == "" {
			continue
		}
		dir = filepath.Join(dir, seg)
		info, err := os.Lstat(dir)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return logging.Wrap(err, logging.ErrInternal, "检查路径的父目录失败")
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return logging.NewAppError(logging.ErrInvalidArgument,
				"路径的父目录含符号链接，拒绝跟随（含指向根内的软链与悬空软链）")
		}
		if !info.IsDir() {
			return logging.NewAppError(logging.ErrInvalidArgument,
				"路径的父目录不是目录")
		}
	}
	return nil
}

// realPathLoosely 返回 p 的真实路径，允许 p 或其祖先尚不存在。
//
// 做法：逐级向上找到最深的存在祖先，对它 EvalSymlinks（真正解析符号链接），
// 再把未存在的尾段原样接回去。这样「父目录还没建」的写请求既不会被误判为
// 逃逸，也不会因为 EvalSymlinks 返回 ENOENT 而整个拒绝。
func realPathLoosely(p string) (string, error) {
	existing := p
	var tail []string
	for {
		resolved, err := filepath.EvalSymlinks(existing)
		if err == nil {
			return filepath.Join(append([]string{resolved}, tail...)...), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return "", err
		}
		tail = append([]string{filepath.Base(existing)}, tail...)
		existing = parent
	}
}

// contentETag 返回内容对应的 git blob hash：sha1("blob <size>\0<content>")。
//
// 与 gitver.BlobHash 同算法，因此在 mirror 根上二者恒等——GET 返回的 ETag 可直接
// 用作 PUT 的 If-Match。这里按内容重算而不调用 repo.BlobHash 的原因：ondemand 根
// 没有仓库可问，而 GET 已经拿到内容，重算可让所有根共用一条读路径。
func contentETag(content []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

// contentTypeFor 按扩展名推断 Content-Type，未知时回 application/octet-stream。
//
// 不使用 mime.TypeByExtension 的嗅探兜底：嗅探会把未知的二进制内容猜成 text/plain，
// 让客户端按文本处理二进制；宁可显式声明 octet-stream。
//
// 注意：本函数只用于「可安全内联展示」的类型，主动内容（见 isActiveContent）不得
// 走这里——handleGetFile 会在调用前拦下它们。
func contentTypeFor(rel string) string {
	if ct := mime.TypeByExtension(strings.ToLower(path.Ext(rel))); ct != "" {
		return ct
	}
	return defaultContentType
}

// activeContentExts 是「浏览器会当作代码执行」的扩展名黑名单（小写，含点）。
//
// 这些类型与服务端同源：攻击者 PUT 一个 evil.svg 后再诱导用户直接访问
// GET /api/files/evil.svg，脚本即在服务端源下执行——可读取 localStorage 里的
// 访问令牌，从而形成存储型 XSS。故读写侧都按「被动附件」对待（强制下载）。
var activeContentExts = map[string]struct{}{
	".html":  {},
	".htm":   {},
	".xhtml": {},
	".shtml": {},
	".ehtml": {},
	".xht":   {},
	".svg":   {},
	".svgz":  {},
	".xml":   {},
	".xsl":   {},
	".js":    {},
	".mjs":   {},
	".mht":   {},
	".rdf":   {},
}

// isActiveContent 报告 rel 的扩展名是否属于主动内容（需强制下载）。
func isActiveContent(rel string) bool {
	_, ok := activeContentExts[strings.ToLower(path.Ext(rel))]
	return ok
}

// contentDispositionFor 构造主动内容的 Content-Disposition：attachment + 文件名。
//
// 文件名只取路径最后一段（path.Base），并把引号、反斜杠与全部控制字符（含 CR/LF）
// 替换为 '_'：filename 参数不可含裸 CR/LF（头注入）与未转义引号（参数提前闭合）。
// 不做 RFC 2231 编码——客户端只需要一个稳定的下载名，非 ASCII 字节被保留即可。
func contentDispositionFor(rel string) string {
	name := strings.Map(func(r rune) rune {
		if r == '"' || r == '\\' || r < 0x20 || r == 0x7f {
			return '_'
		}
		return r
	}, path.Base(rel))
	return `attachment; filename="` + name + `"`
}

// etagMatches 判断条件请求头（If-Match / If-None-Match 的值）是否匹配 etag。
//
// 支持 "*"（资源存在即匹配）、逗号分隔的多个 ETag、强/弱前缀（W/"x" 按 "x" 比较，
// M7 的服务端只发强 ETag，故忽略强弱差异不影响正确性）以及带/不带引号两种写法。
//
// etag 为空串表示「目标当前没有内容」：此时一律返回 false（"*" 由调用方按存在性
// 单独判定）。这条短路是安全前提——否则 `If-Match: ""`（显式空 ETag）会与空 blob
// 「相等」，写侧会把它当成匹配并通过，退化为无条件覆盖。
func etagMatches(header, etag string) bool {
	if etag == "" {
		return false
	}
	for _, part := range strings.Split(header, ",") {
		candidate := strings.TrimSpace(part)
		if candidate == "" {
			continue
		}
		if candidate == "*" {
			// 走到这里 etag 必非空（见上），即「资源存在」。
			return true
		}
		candidate = strings.TrimPrefix(candidate, "W/")
		if strings.Trim(candidate, `"`) == etag {
			return true
		}
	}
	return false
}

// fileETag 流式计算文件的 git blob hash：sha1("blob <size>\0<content>")。
//
// 与 contentETag 同算法（故 GET 的 ETag 与 PUT 返回的 etag 恒等），但按块读取、
// 内存占用 O(1)：GET 因此可以把大文件直接交给 http.ServeContent 流式发送，不必
// 先 os.ReadFile 整个读进内存。size 由调用方取自 FileInfo，不必在此重复 Stat。
// 调用后文件偏移已到末尾，调用方需自行 Seek(0) 才能重读。
func fileETag(f *os.File, size int64) (string, error) {
	h := sha1.New()
	if _, err := fmt.Fprintf(h, "blob %d\x00", size); err != nil {
		return "", err
	}
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// inSubtree 报告 p 是否等于 root 或位于其子树内（按路径段边界判断，
// 故 inSubtree("dir2/a.org", "dir") 为 false）。
//
// 与 internal/webdav/registry.go 的同名私有函数语义一致；刻意复制而不跨包引用：
// api 与 webdav 是两个独立出口，不应依赖对方的内部实现（两处必须同步修改）。
func inSubtree(p, root string) bool {
	return p == root || strings.HasPrefix(p, root+"/")
}

// tombstoneAt 查找 (root, rel) 上仍占位的墓碑（「删除后重建同名路径」的情形）。
//
// 墓碑保留删除前路径，故 UNIQUE(root, path) 仍由它占用：新建同名文件必须复用它的
// uid（等价于复活）才能保持「同一路径重建后身份稳定」，也才不会撞唯一约束。
// IncludeDeleted=true 是为了让墓碑出现在结果里；Prefix 只是粗筛，最终按 Path 精确比对。
func (s *Server) tombstoneAt(rootTag, rel string) (*storage.Entry, bool) {
	entries, err := s.registry.List(storage.ResourceFilter{
		Root:           rootTag,
		Prefix:         rel,
		IncludeDeleted: true,
		Limit:          16,
	})
	if err != nil {
		slog.Error("api: 查询同名墓碑失败", "root", rootTag, "path", rel, "error", err)
		return nil, false
	}
	for i := range entries {
		if entries[i].Path == rel && entries[i].DeletedAt != "" {
			return &entries[i], true
		}
	}
	return nil, false
}

// isRegistryNotFound 判断 err 是否带 ErrNotFound 错误码（登记表中无该路径/资源）。
func isRegistryNotFound(err error) bool {
	var appErr *logging.AppError
	return errors.As(err, &appErr) && appErr.Code == logging.ErrNotFound
}
