package webdav

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/index"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// testRootTag 是测试中登记使用的逻辑根标签。
const testRootTag = "notes"

// newRegistryServer 在 root 上启动「认证 → 索引(nil) → 登记 → commit → WebDAV」的
// 测试服务器（挂载根即仓库根，默认前缀 davPrefix），返回 base URL、登记服务、
// 其 DB（供直接断言登记行）与仓库。
func newRegistryServer(t *testing.T, root string) (string, *registry.Service, *storage.DB, *gitver.Repo) {
	t.Helper()
	return newRegistryServerAt(t, root, root, PolicyOptions{}, davPrefix, "")
}

// newRegistryServerAt 以 repoRoot 打开 git 仓库，在 mountRoot 上挂载带身份登记的
// handler：offset 为 mountRoot 相对 repoRoot 的仓库内偏移（空串表示两者相同），
// 用于覆盖「公开出口为笔记根子目录」的场景。
func newRegistryServerAt(t *testing.T, repoRoot, mountRoot string, opts PolicyOptions, prefix, offset string) (string, *registry.Service, *storage.DB, *gitver.Repo) {
	t.Helper()
	repo, err := gitver.Open(repoRoot)
	if err != nil {
		t.Fatalf("gitver.Open(%s) 失败: %v", repoRoot, err)
	}
	db, err := storage.Open(filepath.Join(t.TempDir(), "registry.db"), "")
	if err != nil {
		t.Fatalf("storage.Open 失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	svc := registry.New(db, repo)
	if err := svc.SetRoots([]registry.Root{{Tag: testRootTag, Path: mountRoot}}); err != nil {
		t.Fatalf("SetRoots 失败: %v", err)
	}

	srv := httptest.NewServer(NewPolicyVersionedHandlerWithRegistry(
		mountRoot, auth.New(testToken), SourceInternal, opts, repo, nil, svc, prefix, offset))
	t.Cleanup(srv.Close)
	return srv.URL, svc, db, repo
}

// allChanges 返回全部变更事件（按 seq 升序）。
func allChanges(t *testing.T, svc *registry.Service) []storage.Change {
	t.Helper()
	changes, _, _, err := svc.Changes(0, 1000)
	if err != nil {
		t.Fatalf("Changes() 失败: %v", err)
	}
	return changes
}

// mustEntry 按 uid 读取登记行，不存在即终止测试。
func mustEntry(t *testing.T, db *storage.DB, uid string) *storage.Entry {
	t.Helper()
	e, err := db.GetResourceByUID(uid)
	if err != nil {
		t.Fatalf("GetResourceByUID(%s) 失败: %v", uid, err)
	}
	return e
}

// uidAtPath 返回 (testRootTag, path) 当前登记的 uid；未登记即终止测试。
func uidAtPath(t *testing.T, svc *registry.Service, path string) string {
	t.Helper()
	uid, err := svc.ResolvePath(testRootTag, path)
	if err != nil {
		t.Fatalf("ResolvePath(%s) 失败: %v", path, err)
	}
	return uid
}

// doMethod 发送带认证的 MOVE/COPY 等需要额外头的请求。
func doMethod(t *testing.T, method, url, destination string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		t.Fatalf("构造 %s 请求失败: %v", method, err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	if destination != "" {
		req.Header.Set("Destination", destination)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s 请求失败: %v", method, url, err)
	}
	return resp
}

// TestRegistryPutCreatesResourceAndChange 验证 PUT 新建在 resources 留下 uid，
// 在 changes 留下 create 事件，且 rev 取 commit 之后的 HEAD。
func TestRegistryPutCreatesResourceAndChange(t *testing.T) {
	root := t.TempDir()
	base, svc, db, repo := newRegistryServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	changes := allChanges(t, svc)
	if len(changes) != 1 {
		t.Fatalf("变更事件数 = %d, 期望 1: %+v", len(changes), changes)
	}
	c := changes[0]
	if c.Op != storage.OpCreate {
		t.Errorf("op = %q, 期望 %q", c.Op, storage.OpCreate)
	}
	if c.Root != testRootTag || c.Path != "a.org" {
		t.Errorf("root/path = %q/%q, 期望 %q/a.org", c.Root, c.Path, testRootTag)
	}
	if !registry.IsUID(c.UID) {
		t.Fatalf("事件 uid = %q, 不是合法 uid", c.UID)
	}

	e := mustEntry(t, db, c.UID)
	if e.Path != "a.org" || e.DeletedAt != "" {
		t.Errorf("登记行 path/deleted = %q/%q, 期望 a.org/空", e.Path, e.DeletedAt)
	}
	if e.Blob == "" {
		t.Error("登记行 blob 为空，期望非空（内容哈希）")
	}
	if e.Size == 0 || e.Mtime == 0 {
		t.Errorf("登记行 size/mtime = %d/%d, 期望均非 0", e.Size, e.Mtime)
	}

	head, err := repo.Head()
	if err != nil {
		t.Fatalf("Head() 失败: %v", err)
	}
	if c.Rev != head {
		t.Errorf("事件 rev = %q, 期望 commit 后的 HEAD %q", c.Rev, head)
	}
}

// TestRegistryPutTwiceUpdatesSameUID 验证同路径再次 PUT 保持 uid 不变并追加 update。
func TestRegistryPutTwiceUpdatesSameUID(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	for _, content := range []string{"* 第一版\n", "* 第二版\n"} {
		resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", content, basicAuthHeader(testToken))
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("PUT 状态码 = %d, 期望 2xx", resp.StatusCode)
		}
	}

	changes := allChanges(t, svc)
	if len(changes) != 2 {
		t.Fatalf("变更事件数 = %d, 期望 2: %+v", len(changes), changes)
	}
	if changes[0].Op != storage.OpCreate {
		t.Errorf("首条 op = %q, 期望 create", changes[0].Op)
	}
	if changes[1].Op != storage.OpUpdate {
		t.Errorf("次条 op = %q, 期望 update", changes[1].Op)
	}
	if changes[0].UID != changes[1].UID {
		t.Errorf("两次 PUT 的 uid 不同: %q vs %q", changes[0].UID, changes[1].UID)
	}
	if uid := uidAtPath(t, svc, "a.org"); uid != changes[0].UID {
		t.Errorf("路径解析 uid = %q, 期望 %q", uid, changes[0].UID)
	}
}

// TestRegistryMoveFileKeepsUID 验证 MOVE 文件：uid 不变、rename 事件记正确 old_path。
func TestRegistryMoveFileKeepsUID(t *testing.T) {
	root := t.TempDir()
	base, svc, db, _ := newRegistryServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	uid := uidAtPath(t, svc, "a.org")

	moveResp := doMethod(t, "MOVE", base+davPrefix+"/a.org", base+davPrefix+"/b.org")
	moveResp.Body.Close()
	if moveResp.StatusCode < 200 || moveResp.StatusCode >= 300 {
		t.Fatalf("MOVE 状态码 = %d, 期望 2xx", moveResp.StatusCode)
	}

	changes := allChanges(t, svc)
	if len(changes) != 2 {
		t.Fatalf("变更事件数 = %d, 期望 2: %+v", len(changes), changes)
	}
	rename := changes[1]
	if rename.Op != storage.OpRename {
		t.Fatalf("op = %q, 期望 rename", rename.Op)
	}
	if rename.UID != uid {
		t.Errorf("rename 事件 uid = %q, 期望 %q（uid 应跨改名稳定）", rename.UID, uid)
	}
	if rename.OldPath != "a.org" || rename.Path != "b.org" {
		t.Errorf("old_path/path = %q/%q, 期望 a.org/b.org", rename.OldPath, rename.Path)
	}

	e := mustEntry(t, db, uid)
	if e.Path != "b.org" {
		t.Errorf("登记行 path = %q, 期望 b.org", e.Path)
	}
	if got := uidAtPath(t, svc, "b.org"); got != uid {
		t.Errorf("新路径解析 uid = %q, 期望 %q", got, uid)
	}
}

// TestRegistryMoveDirRenamesAll 验证目录 MOVE：子树内每个文件各产生一条 rename，
// 新路径保留相对层级。
func TestRegistryMoveDirRenamesAll(t *testing.T) {
	root := t.TempDir()
	base, svc, db, _ := newRegistryServer(t, root)

	mkcol := doRequest(t, "MKCOL", base+davPrefix+"/dir", "", basicAuthHeader(testToken))
	mkcol.Body.Close()
	if mkcol.StatusCode != http.StatusCreated {
		t.Fatalf("MKCOL 状态码 = %d, 期望 201", mkcol.StatusCode)
	}
	for _, name := range []string{"a.org", "b.org"} {
		resp := doRequest(t, http.MethodPut, base+davPrefix+"/dir/"+name, "* "+name+"\n", basicAuthHeader(testToken))
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("PUT %s 状态码 = %d, 期望 2xx", name, resp.StatusCode)
		}
	}

	uidA := uidAtPath(t, svc, "dir/a.org")
	uidB := uidAtPath(t, svc, "dir/b.org")

	moveResp := doMethod(t, "MOVE", base+davPrefix+"/dir", base+davPrefix+"/renamed")
	moveResp.Body.Close()
	if moveResp.StatusCode < 200 || moveResp.StatusCode >= 300 {
		t.Fatalf("MOVE 目录状态码 = %d, 期望 2xx", moveResp.StatusCode)
	}

	var renames []storage.Change
	for _, c := range allChanges(t, svc) {
		if c.Op == storage.OpRename {
			renames = append(renames, c)
		}
	}
	if len(renames) != 2 {
		t.Fatalf("rename 事件数 = %d, 期望 2: %+v", len(renames), renames)
	}

	want := map[string]string{
		"dir/a.org": "renamed/a.org",
		"dir/b.org": "renamed/b.org",
	}
	for _, c := range renames {
		to, ok := want[c.OldPath]
		if !ok {
			t.Errorf("意外的 rename 源路径 %q", c.OldPath)
			continue
		}
		if c.Path != to {
			t.Errorf("rename %q → %q, 期望 %q", c.OldPath, c.Path, to)
		}
	}

	if got := mustEntry(t, db, uidA).Path; got != "renamed/a.org" {
		t.Errorf("a 登记行 path = %q, 期望 renamed/a.org", got)
	}
	if got := mustEntry(t, db, uidB).Path; got != "renamed/b.org" {
		t.Errorf("b 登记行 path = %q, 期望 renamed/b.org", got)
	}
}

// TestRegistryDeleteFileTombstones 验证 DELETE 文件：登记写墓碑且产生 delete 事件。
func TestRegistryDeleteFileTombstones(t *testing.T) {
	root := t.TempDir()
	base, svc, db, _ := newRegistryServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	uid := uidAtPath(t, svc, "a.org")

	delResp := doRequest(t, http.MethodDelete, base+davPrefix+"/a.org", "", basicAuthHeader(testToken))
	delResp.Body.Close()
	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 204", delResp.StatusCode)
	}

	changes := allChanges(t, svc)
	last := changes[len(changes)-1]
	if last.Op != storage.OpDelete {
		t.Fatalf("末条 op = %q, 期望 delete", last.Op)
	}
	if last.UID != uid || last.Path != "a.org" {
		t.Errorf("delete 事件 uid/path = %q/%q, 期望 %q/a.org", last.UID, last.Path, uid)
	}

	e := mustEntry(t, db, uid)
	if e.DeletedAt == "" {
		t.Error("登记行 deleted_at 为空，期望墓碑")
	}
	if e.Path != "a.org" {
		t.Errorf("墓碑保留的 path = %q, 期望 a.org", e.Path)
	}
}

// TestRegistryDeleteDirTombstonesAll 验证目录 DELETE：子树内每个存活登记各产生一条
// delete 事件。
func TestRegistryDeleteDirTombstonesAll(t *testing.T) {
	root := t.TempDir()
	base, svc, db, _ := newRegistryServer(t, root)

	mkcol := doRequest(t, "MKCOL", base+davPrefix+"/dir", "", basicAuthHeader(testToken))
	mkcol.Body.Close()
	for _, name := range []string{"a.org", "b.org"} {
		resp := doRequest(t, http.MethodPut, base+davPrefix+"/dir/"+name, "* "+name+"\n", basicAuthHeader(testToken))
		resp.Body.Close()
	}
	uidA := uidAtPath(t, svc, "dir/a.org")
	uidB := uidAtPath(t, svc, "dir/b.org")

	delResp := doRequest(t, http.MethodDelete, base+davPrefix+"/dir", "", basicAuthHeader(testToken))
	delResp.Body.Close()
	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE 目录状态码 = %d, 期望 204", delResp.StatusCode)
	}

	var deletes []storage.Change
	for _, c := range allChanges(t, svc) {
		if c.Op == storage.OpDelete {
			deletes = append(deletes, c)
		}
	}
	if len(deletes) != 2 {
		t.Fatalf("delete 事件数 = %d, 期望 2: %+v", len(deletes), deletes)
	}

	for uid, wantPath := range map[string]string{uidA: "dir/a.org", uidB: "dir/b.org"} {
		if e := mustEntry(t, db, uid); e.DeletedAt == "" {
			t.Errorf("%s 未写墓碑", wantPath)
		}
	}
}

// TestRegistryCopyFileNewUID 验证 COPY 文件：目标为新 uid 且产生 create 事件，
// 源登记与 uid 不受影响。
func TestRegistryCopyFileNewUID(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	srcUID := uidAtPath(t, svc, "a.org")

	copyResp := doMethod(t, "COPY", base+davPrefix+"/a.org", base+davPrefix+"/b.org")
	copyResp.Body.Close()
	if copyResp.StatusCode < 200 || copyResp.StatusCode >= 300 {
		t.Fatalf("COPY 状态码 = %d, 期望 2xx", copyResp.StatusCode)
	}

	changes := allChanges(t, svc)
	if len(changes) != 2 {
		t.Fatalf("变更事件数 = %d, 期望 2: %+v", len(changes), changes)
	}
	c := changes[1]
	if c.Op != storage.OpCreate {
		t.Fatalf("op = %q, 期望 create", c.Op)
	}
	if c.Path != "b.org" {
		t.Errorf("path = %q, 期望 b.org", c.Path)
	}
	if c.UID == srcUID {
		t.Error("COPY 目标复用了源 uid，期望独立新 uid")
	}

	if got := uidAtPath(t, svc, "a.org"); got != srcUID {
		t.Errorf("源路径 uid = %q, 期望保持 %q", got, srcUID)
	}
	if got := uidAtPath(t, svc, "b.org"); got != c.UID {
		t.Errorf("目标路径 uid = %q, 期望 %q", got, c.UID)
	}
}

// TestRegistryCopyDirCreatesChildren 验证 COPY 目录：目标目录下每个文件各登记一个
// 新 uid（与源 uid 不同）。
func TestRegistryCopyDirCreatesChildren(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	mkcol := doRequest(t, "MKCOL", base+davPrefix+"/dir", "", basicAuthHeader(testToken))
	mkcol.Body.Close()
	for _, name := range []string{"a.org", "b.org"} {
		resp := doRequest(t, http.MethodPut, base+davPrefix+"/dir/"+name, "* "+name+"\n", basicAuthHeader(testToken))
		resp.Body.Close()
	}
	srcA := uidAtPath(t, svc, "dir/a.org")
	srcB := uidAtPath(t, svc, "dir/b.org")

	copyResp := doMethod(t, "COPY", base+davPrefix+"/dir", base+davPrefix+"/copy")
	copyResp.Body.Close()
	if copyResp.StatusCode < 200 || copyResp.StatusCode >= 300 {
		t.Fatalf("COPY 目录状态码 = %d, 期望 2xx", copyResp.StatusCode)
	}

	dstA := uidAtPath(t, svc, "copy/a.org")
	dstB := uidAtPath(t, svc, "copy/b.org")
	for _, pair := range [][2]string{{srcA, dstA}, {srcB, dstB}} {
		if pair[0] == pair[1] {
			t.Errorf("复制目标复用了源 uid: %q", pair[0])
		}
	}
}

// TestRegistryReadOnlyNoChanges 验证失败的写请求（只读出口 403）不产生任何登记。
func TestRegistryReadOnlyNoChanges(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServerAt(t, root, root, PolicyOptions{ReadOnly: true}, "/public", "")

	resp := doRequest(t, http.MethodPut, base+"/public/new.org", "* blocked\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Fatalf("只读下 PUT 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}

	if changes := allChanges(t, svc); len(changes) != 0 {
		t.Errorf("失败请求后变更事件 = %d, 期望 0: %+v", len(changes), changes)
	}
}

// TestRegistryPublicOffsetPath 验证对外出口（挂载根为笔记根子目录）登记路径带 offset：
// 请求 /public/a.org 登记为 public/a.org，与内部端点的仓库内路径对齐。
func TestRegistryPublicOffsetPath(t *testing.T) {
	repoRoot := t.TempDir()
	mountRoot := filepath.Join(repoRoot, "public")
	if err := os.MkdirAll(mountRoot, 0o755); err != nil {
		t.Fatalf("创建对外出口目录失败: %v", err)
	}
	base, svc, _, _ := newRegistryServerAt(t, repoRoot, mountRoot,
		PolicyOptions{AllowExts: []string{".org"}}, "/public", "public")

	resp := doRequest(t, http.MethodPut, base+"/public/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 201", resp.StatusCode)
	}

	changes := allChanges(t, svc)
	if len(changes) != 1 {
		t.Fatalf("变更事件数 = %d, 期望 1: %+v", len(changes), changes)
	}
	if changes[0].Path != "public/a.org" {
		t.Errorf("登记 path = %q, 期望 public/a.org（带 offset）", changes[0].Path)
	}
	if got := uidAtPath(t, svc, "public/a.org"); got != changes[0].UID {
		t.Errorf("按带 offset 路径解析 uid = %q, 期望 %q", got, changes[0].UID)
	}
}

// TestRegistryPutOverTombstoneReusesUID 验证「先删后写同一路径」复用墓碑 uid：
// 事件为 update（由 registry.Apply 归一并复活），不因 UNIQUE(root,path) 冲突丢事件。
func TestRegistryPutOverTombstoneReusesUID(t *testing.T) {
	root := t.TempDir()
	base, svc, db, _ := newRegistryServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* 第一版\n", basicAuthHeader(testToken))
	resp.Body.Close()
	uid := uidAtPath(t, svc, "a.org")

	delResp := doRequest(t, http.MethodDelete, base+davPrefix+"/a.org", "", basicAuthHeader(testToken))
	delResp.Body.Close()

	// 删除后按路径已不可解析（墓碑），再写同一路径。
	putResp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* 复活\n", basicAuthHeader(testToken))
	putResp.Body.Close()
	if putResp.StatusCode < 200 || putResp.StatusCode >= 300 {
		t.Fatalf("复活 PUT 状态码 = %d, 期望 2xx", putResp.StatusCode)
	}

	changes := allChanges(t, svc)
	last := changes[len(changes)-1]
	if last.UID != uid {
		t.Errorf("复活后 uid = %q, 期望复用墓碑 uid %q", last.UID, uid)
	}
	if last.Op != storage.OpCreate {
		t.Errorf("复活事件 op = %q, 期望 create（墓碑被复活）", last.Op)
	}

	e := mustEntry(t, db, uid)
	if e.DeletedAt != "" {
		t.Errorf("复活后 deleted_at = %q, 期望空（清除墓碑）", e.DeletedAt)
	}
	if e.Path != "a.org" {
		t.Errorf("复活后 path = %q, 期望 a.org", e.Path)
	}
}

// TestRegistryNilServiceNoop 验证 svc 为 nil 时 registryAfterWrite 不 panic、
// 且不改变响应状态（透传内层结果）。
func TestRegistryNilServiceNoop(t *testing.T) {
	root := t.TempDir()
	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("gitver.Open 失败: %v", err)
	}

	for _, tc := range []struct {
		name string
		code int
	}{{"成功响应", http.StatusCreated}, {"失败响应", http.StatusForbidden}} {
		t.Run(tc.name, func(t *testing.T) {
			inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.code)
			})
			srv := httptest.NewServer(registryAfterWrite(testRootTag, davPrefix, "", nil, repo, inner))
			defer srv.Close()

			resp := doRequest(t, http.MethodPut, srv.URL+davPrefix+"/a.org", "* a\n", "")
			resp.Body.Close()
			if resp.StatusCode != tc.code {
				t.Errorf("状态码 = %d, 期望 %d", resp.StatusCode, tc.code)
			}
		})
	}
}

// TestRegistryWithIndexerCoexists 验证「索引钩子 + 登记钩子」两层 statusRecorder
// 嵌套共存：同一次 PUT 既写全文索引，也写登记事件。
func TestRegistryWithIndexerCoexists(t *testing.T) {
	root := t.TempDir()
	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("gitver.Open 失败: %v", err)
	}
	db, err := storage.Open(filepath.Join(t.TempDir(), "coexist.db"), "")
	if err != nil {
		t.Fatalf("storage.Open 失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	svc := registry.New(db, repo)
	if err := svc.SetRoots([]registry.Root{{Tag: testRootTag, Path: root}}); err != nil {
		t.Fatalf("SetRoots 失败: %v", err)
	}
	ix := index.New(db)

	srv := httptest.NewServer(NewPolicyVersionedHandlerWithRegistry(
		root, auth.New(testToken), SourceInternal, PolicyOptions{}, repo, ix, svc, davPrefix, ""))
	t.Cleanup(srv.Close)

	resp := doRequest(t, http.MethodPut, srv.URL+davPrefix+"/note.org", "* coexist token\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 201", resp.StatusCode)
	}

	changes := allChanges(t, svc)
	if len(changes) != 1 || changes[0].Op != storage.OpCreate {
		t.Fatalf("登记事件 = %+v, 期望单条 create", changes)
	}

	paths, err := ix.Search("coexist", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(paths, "note.org") {
		t.Errorf("索引未命中 note.org（两层 recorder 共存可能有问题）: %v", paths)
	}
}

// putOrg 通过 WebDAV 写入一个 .org 文件并返回其登记 uid（写入失败即终止用例）。
func putOrg(t *testing.T, svc *registry.Service, base, rel, content string) string {
	t.Helper()
	resp := doRequest(t, http.MethodPut, base+davPrefix+"/"+rel, content, basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		t.Fatalf("PUT %s 状态码 = %d, 期望 2xx", rel, resp.StatusCode)
	}
	return uidAtPath(t, svc, rel)
}

// outRefs 返回某 uid 的出边（我引用了谁）。
func outRefs(t *testing.T, svc *registry.Service, uid string) []storage.Ref {
	t.Helper()
	refs, err := svc.ListRefs(uid, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs(%s, out) 失败: %v", uid, err)
	}
	return refs
}

// TestRegistryPutOrgWritesRefs 验证 PUT 含两个 seshat: 链接的 .org 后写入 2 条引用，
// 且 tag:path 形态的目标也被解析为 uid（C2 的三形态之一）。
func TestRegistryPutOrgWritesRefs(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	uid1 := putOrg(t, svc, base, "target1.org", "* 目标一\n")
	uid2 := putOrg(t, svc, base, "target2.org", "* 目标二\n")

	src := "* 源\n[[seshat:" + uid1 + "]]\n[[seshat:notes:target2.org#p.2][目标二第 2 页]]\n"
	uidSrc := putOrg(t, svc, base, "src.org", src)

	refs := outRefs(t, svc, uidSrc)
	if len(refs) != 2 {
		t.Fatalf("引用条数 = %d, 期望 2: %+v", len(refs), refs)
	}
	targets := map[string]string{}
	for _, r := range refs {
		if r.SourceUID != uidSrc {
			t.Errorf("source_uid = %q, 期望 %q", r.SourceUID, uidSrc)
		}
		targets[r.TargetUID] = r.TargetLocation
	}
	if _, ok := targets[uid1]; !ok {
		t.Errorf("缺少指向 uid 形态目标的引用: %+v", refs)
	}
	if loc, ok := targets[uid2]; !ok || loc != "p.2" {
		t.Errorf("tag:path 目标的引用 = (%q, %v), 期望 (%q, true)", loc, ok, "p.2")
	}
}

// TestRegistryPutOrgReplacesRefs 验证再次 PUT 改为 1 个链接后引用被整份替换为 1 条。
func TestRegistryPutOrgReplacesRefs(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	uid1 := putOrg(t, svc, base, "target1.org", "* 目标一\n")
	uid2 := putOrg(t, svc, base, "target2.org", "* 目标二\n")

	uidSrc := putOrg(t, svc, base, "src.org",
		"[[seshat:"+uid1+"]] [[seshat:"+uid2+"]]\n")
	if refs := outRefs(t, svc, uidSrc); len(refs) != 2 {
		t.Fatalf("首次引用条数 = %d, 期望 2", len(refs))
	}

	uidAgain := putOrg(t, svc, base, "src.org", "只留 [[seshat:"+uid2+"]]\n")
	if uidAgain != uidSrc {
		t.Fatalf("覆盖 PUT 后 uid = %q, 期望不变 %q", uidAgain, uidSrc)
	}
	refs := outRefs(t, svc, uidSrc)
	if len(refs) != 1 {
		t.Fatalf("覆盖后引用条数 = %d, 期望 1: %+v", len(refs), refs)
	}
	if refs[0].TargetUID != uid2 {
		t.Fatalf("覆盖后目标 = %q, 期望 %q", refs[0].TargetUID, uid2)
	}
}

// TestRegistryDeleteClearsRefs 验证 DELETE 源文件后其引用被清空。
func TestRegistryDeleteClearsRefs(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	uid1 := putOrg(t, svc, base, "target1.org", "* 目标一\n")
	uidSrc := putOrg(t, svc, base, "src.org", "[[seshat:"+uid1+"]]\n")
	if refs := outRefs(t, svc, uidSrc); len(refs) != 1 {
		t.Fatalf("删除前引用条数 = %d, 期望 1", len(refs))
	}

	resp := doRequest(t, http.MethodDelete, base+davPrefix+"/src.org", "", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		t.Fatalf("DELETE 状态码 = %d, 期望 2xx", resp.StatusCode)
	}

	if refs := outRefs(t, svc, uidSrc); len(refs) != 0 {
		t.Fatalf("删除后引用 = %+v, 期望为空", refs)
	}
}

// TestRegistryCopyFileWritesRefs 验证 COPY 单个 .org 文件后，目标新 uid 上建立了
// 引用记录（copy 的内容里含 1 个 seshat: 链接），且源 uid 的引用不受影响。
func TestRegistryCopyFileWritesRefs(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	targetUID := putOrg(t, svc, base, "target.org", "* 目标\n")
	srcUID := putOrg(t, svc, base, "src.org", "[[seshat:"+targetUID+"]]\n")
	if refs := outRefs(t, svc, srcUID); len(refs) != 1 {
		t.Fatalf("COPY 前源引用条数 = %d, 期望 1: %+v", len(refs), refs)
	}

	copyResp := doMethod(t, "COPY", base+davPrefix+"/src.org", base+davPrefix+"/dst.org")
	copyResp.Body.Close()
	if copyResp.StatusCode < 200 || copyResp.StatusCode >= 300 {
		t.Fatalf("COPY 状态码 = %d, 期望 2xx", copyResp.StatusCode)
	}

	dstUID := uidAtPath(t, svc, "dst.org")
	if dstUID == srcUID {
		t.Fatalf("COPY 目标复用了源 uid: %q", dstUID)
	}

	dstRefs := outRefs(t, svc, dstUID)
	if len(dstRefs) != 1 {
		t.Fatalf("COPY 目标引用条数 = %d, 期望 1: %+v", len(dstRefs), dstRefs)
	}
	if dstRefs[0].SourceUID != dstUID {
		t.Errorf("source_uid = %q, 期望 %q", dstRefs[0].SourceUID, dstUID)
	}
	if dstRefs[0].TargetUID != targetUID {
		t.Errorf("target_uid = %q, 期望 %q", dstRefs[0].TargetUID, targetUID)
	}

	// 源文件的引用必须保持原样（不被覆盖，也不被清空）。
	srcRefs := outRefs(t, svc, srcUID)
	if len(srcRefs) != 1 || srcRefs[0].TargetUID != targetUID {
		t.Errorf("COPY 后源引用 = %+v, 期望仍为 1 条指向 %q", srcRefs, targetUID)
	}

	// 扩展名大小写不影响引用刷新：COPY 到 .ORG 也应建立 refs。
	upperResp := doMethod(t, "COPY", base+davPrefix+"/src.org", base+davPrefix+"/dst2.ORG")
	upperResp.Body.Close()
	if upperResp.StatusCode < 200 || upperResp.StatusCode >= 300 {
		t.Fatalf("COPY 到大写扩展名状态码 = %d, 期望 2xx", upperResp.StatusCode)
	}
	upperUID := uidAtPath(t, svc, "dst2.ORG")
	if refs := outRefs(t, svc, upperUID); len(refs) != 1 || refs[0].TargetUID != targetUID {
		t.Errorf("大写扩展名目标的引用 = %+v, 期望 1 条指向 %q", refs, targetUID)
	}
}

// TestRegistryCopyDirWritesRefs 验证 COPY 目录后，目标目录下的 .org 全部被登记，
// 其中含链接者的引用挂在各自的新 uid 上（不是源 uid）。
func TestRegistryCopyDirWritesRefs(t *testing.T) {
	root := t.TempDir()
	base, svc, _, _ := newRegistryServer(t, root)

	targetUID := putOrg(t, svc, base, "target.org", "* 目标\n")

	mkcol := doRequest(t, "MKCOL", base+davPrefix+"/dir", "", basicAuthHeader(testToken))
	mkcol.Body.Close()
	srcA := putOrg(t, svc, base, "dir/a.org", "见 [[seshat:"+targetUID+"]]\n")
	srcB := putOrg(t, svc, base, "dir/b.org", "* 无链接\n")
	if refs := outRefs(t, svc, srcA); len(refs) != 1 {
		t.Fatalf("COPY 前 dir/a.org 引用条数 = %d, 期望 1: %+v", len(refs), refs)
	}

	copyResp := doMethod(t, "COPY", base+davPrefix+"/dir", base+davPrefix+"/copy")
	copyResp.Body.Close()
	if copyResp.StatusCode < 200 || copyResp.StatusCode >= 300 {
		t.Fatalf("COPY 目录状态码 = %d, 期望 2xx", copyResp.StatusCode)
	}

	dstA := uidAtPath(t, svc, "copy/a.org")
	dstB := uidAtPath(t, svc, "copy/b.org")
	for _, pair := range [][2]string{{srcA, dstA}, {srcB, dstB}} {
		if pair[0] == pair[1] {
			t.Errorf("复制目标复用了源 uid: %q", pair[0])
		}
	}

	refsA := outRefs(t, svc, dstA)
	if len(refsA) != 1 {
		t.Fatalf("copy/a.org 引用条数 = %d, 期望 1: %+v", len(refsA), refsA)
	}
	if refsA[0].SourceUID != dstA || refsA[0].TargetUID != targetUID {
		t.Errorf("copy/a.org 引用 = %+v, 期望 source=%q target=%q", refsA, dstA, targetUID)
	}
	if refsB := outRefs(t, svc, dstB); len(refsB) != 0 {
		t.Errorf("copy/b.org 引用 = %+v, 期望为空", refsB)
	}

	// 源目录内文件的引用不受影响。
	if refs := outRefs(t, svc, srcA); len(refs) != 1 || refs[0].TargetUID != targetUID {
		t.Errorf("dir/a.org 引用 = %+v, 期望仍为 1 条指向 %q", refs, targetUID)
	}
}
