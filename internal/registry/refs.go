// 本文件实现 M7 C1/C2 的引用层：从 org 文本提取 seshat: 链接、把目标解析为 uid、
// 以「整份替换」语义维护 refs 表，并提供双向查询。
//
// 设计取舍：
//   - 解析与解析 uid 分离：ParseSeshatLinks 是纯函数（文本 → 原样 target + location），
//     RefreshRefs 才做「target → uid」的解析，便于单测两层各自的行为；
//   - 引用采用整份替换（storage.ReplaceRefs 单事务先删后插）而非增量 diff：org 写入是
//     全量覆盖，重解析全文比 diff 简单且不会漏删；
//   - 目标解析不到只跳过该条（文件里的链接可以指向尚未同步的文档），不使整次刷新失败；
//   - 单份文档的引用条数上限为 maxRefsPerDocument（2000），超出则按首次出现顺序截断并
//     记一行日志：每条链接都要走一次 Resolve 查询，而 DB 是单连接，超大文档的逐条解析
//     会把一次写入拖成分钟级的独占占用；
//   - 禁止在事务内做文件 IO：先读内容 → 解析 → 再一次 ReplaceRefs。DB 是单连接
//     （SetMaxOpenConns(1)），长事务会阻塞全部读写。
//
// 链接形态（C2 起两种，M8-C T8 起四种）：
//   - seshat:<uid>#<loc>          裸 uid（服务端权威身份）；
//   - seshat:uid:<uid>#<loc>      显式前缀形态，客户端（Emacs 端）产出；
//   - seshat:<tag>:<path>#<loc>   人类可读的 doc-id（首个冒号前为根 tag）；
//   - seshat:<path>#<loc>         纯 path，走默认根。
//
// 解析优先级（四段，由 Service.Resolve 承担 —— 本文件只是调用方）：空 key 报错 → 裸 uid
// → `uid:` + 合法 uid → tag:path / 默认根纯路径；`uid:` 之后不是合法 uid 时回落
// tag:path（因此根 tag 名为 uid 的部署仍可用）。
package registry

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"seshat/internal/logging"
	"seshat/internal/storage"
)

// seshatLinkPattern 匹配 org 文本中的 seshat: 链接。
//
// target 段取到 '#'、空白、')'、']' 为止（org 链接与裸文本共用一种写法）；
// location 段为可选的 '#' 及其后到 ')'/']'/空白为止的内容。用 MustCompile 的包级
// 变量避免每次解析重复编译（正则是常量，语法错误会在包初始化时直接 panic）。
var seshatLinkPattern = regexp.MustCompile(`seshat:([^#\s)\]]+)(#[^)\]\s]+)?`)

// maxRefsPerDocument 是单份文档保留的引用条数上限。
//
// 理由：DB 为单写者单连接（db.go 的 SetMaxOpenConns(1)），每条待落库的链接都要走
// 一次 Service.Resolve 查询；一份 32MiB 上限内的 org 文件可以写出数百万条不同
// target 的链接，逐条解析会把一次写入变成分钟级的独占 DB 占用。因此超出上限时
// 截断而非拒绝——写本身应当成功，引用图只保留前 maxRefsPerDocument 条（顺序为
// 文本中首次出现的顺序，故结果对同一份内容稳定可复现）。
const maxRefsPerDocument = 2000

// maxTargetLogBytes 是日志里单个 target 的最大字节数。
//
// 日志**不是**内容通道：org 文件上限 32MiB，一条链接的 target 可以长到接近该
// 上限（无空白的超长串），原样 `%q' 打进日志既污染日志文件，也可能把用户内容
// 无谓地带进运维视线。因此只记前缀，超出部分以省略号收尾。
const maxTargetLogBytes = 120

// truncateForLog 把 s 截断到最多 limit 字节并补省略号；未超限时原样返回。
//
// 截断点回退到 UTF-8 字符边界，避免日志里出现半个多字节字符（写出来是乱码）。
func truncateForLog(s string, limit int) string {
	if limit <= 0 || len(s) <= limit {
		return s
	}
	cut := limit
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

// Link 是解析后的引用（target 已解析为 uid），对外/内部共用。
type Link struct {
	TargetUID      string
	TargetLocation string
}

// ParsedLink 是从文本原样解析出的链接：Target 可能是 uid、tag:path 或纯 path，
// 尚未解析为 uid；Location 为空表示链接不带位置锚点（'#' 已被剥离）。
type ParsedLink struct {
	Target   string
	Location string
}

// ParseSeshatLinks 从 org 文本中提取 seshat: 链接（去重、保序）。
//
// 去重键为 target + "#" + location（同一目标的不同位置被视为不同引用）；
// 顺序按首次出现位置，使引用列表对同一份内容稳定可复现。target 为空的匹配
// （如 "seshat: 空格..." 或 "seshat:]]"）直接丢弃。
func ParseSeshatLinks(content string) []ParsedLink {
	matches := seshatLinkPattern.FindAllStringSubmatch(content, -1)
	if len(matches) == 0 {
		return []ParsedLink{}
	}

	links := make([]ParsedLink, 0, len(matches))
	seen := make(map[string]struct{}, len(matches))
	for _, m := range matches {
		target := strings.TrimSpace(m[1])
		if target == "" {
			continue
		}
		location := strings.TrimSpace(strings.TrimPrefix(m[2], "#"))
		key := target + "#" + location
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		links = append(links, ParsedLink{Target: target, Location: location})
	}
	return links
}

// RefreshRefs 读取 root 下 relPath 的 .org 内容，解析链接、解析目标 uid，并用结果
// 整份替换该源的全部引用。
//
// 非 .org 路径不读文件（避免无意义的 IO），直接清空该源的引用——源文件名从 .org
// 改成其它扩展名后，旧链接必须随之消失。内容读取失败返回错误，调用方只记日志；
// 目标解析失败（未登记/非法/逃逸）只跳过该条并记一行日志（含 target 与源 uid，
// **不打印文件内容**）。
func (s *Service) RefreshRefs(rootTag, relPath string) error {
	cleanPath, err := normalizeResourcePath(relPath)
	if err != nil {
		return err
	}

	sourceUID, err := s.ResolvePath(rootTag, cleanPath)
	if err != nil {
		return err
	}

	if !strings.HasSuffix(strings.ToLower(cleanPath), ".org") {
		return s.db.ReplaceRefs(sourceUID, nil)
	}

	rootDir, err := s.rootPath(rootTag)
	if err != nil {
		return err
	}
	physical := filepath.Join(rootDir, filepath.FromSlash(cleanPath))
	content, err := os.ReadFile(physical)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取内容以解析引用失败: "+cleanPath)
	}

	// 文件 IO 已结束，此处才进事务（ReplaceRefs 内部单事务）。
	return s.db.ReplaceRefs(sourceUID, s.resolveLinks(sourceUID, string(content)))
}

// ClearRefs 清空某源的全部引用（文件删除时用）。sourceUID 未登记也不会报错——
// 删除路径上重复清理是正常情形。
func (s *Service) ClearRefs(sourceUID string) error {
	return s.db.ReplaceRefs(sourceUID, nil)
}

// ListRefs 查询引用（direction: "in" | "out"）。
//
// in 返回「谁引用了我」（按 target_uid 过滤），out 返回「我引用了谁」（按 source_uid
// 过滤），空 direction 按 out 处理；其它取值返回 ErrInvalidArgument。归属校验
// （uid 形态、是否登记/墓碑）由调用方（api 层）完成，使「400 invalid_uid」与
// 「404 unknown_uid」的分流集中在一处。
func (s *Service) ListRefs(uid, direction string) ([]storage.Ref, error) {
	if strings.TrimSpace(uid) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "引用查询 uid 不能为空")
	}
	switch direction {
	case "", storage.RefDirectionIn, storage.RefDirectionOut:
	default:
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "direction 必须是 in 或 out")
	}
	return s.db.ListRefs(uid, direction)
}

// resolveLinks 把文本中的链接解析成 storage.Ref 列表（target → uid），跳过解析不到的目标。
//
// 去重键为「解析后的 uid + location」：不同写法（uid 形态与 tag:path 形态）可能指向
// 同一文档的同一位置，落库时它们是同一条边，提前合并可使结果稳定（不必依赖
// INSERT OR REPLACE 的兜底）。
//
// 条数上限为 maxRefsPerDocument：超出时按首次出现顺序截断并记一行日志（只含 source
// uid 与计数，不含文件内容），使写入仍然成功而不是因「链接太多」整份失败。
func (s *Service) resolveLinks(sourceUID, content string) []storage.Ref {
	parsed := ParseSeshatLinks(content)
	if len(parsed) > maxRefsPerDocument {
		log.Printf("registry: 引用条数超过上限，已截断: source=%s parsed=%d limit=%d",
			sourceUID, len(parsed), maxRefsPerDocument)
		parsed = parsed[:maxRefsPerDocument]
	}

	refs := make([]storage.Ref, 0, len(parsed))
	seen := make(map[string]struct{}, len(parsed))

	for _, link := range parsed {
		targetUID, err := s.Resolve(link.Target)
		if err != nil {
			log.Printf("registry: 引用目标无法解析，已忽略: source=%s target=%q",
				sourceUID, truncateForLog(link.Target, maxTargetLogBytes))
			continue
		}
		key := targetUID + "#" + link.Location
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		refs = append(refs, storage.Ref{
			SourceUID:      sourceUID,
			SourceLocation: "",
			TargetUID:      targetUID,
			TargetLocation: link.Location,
		})
	}
	return refs
}

// rootPath 返回 root tag 对应的物理根目录（SetRoots 登记的值）。
//
// 未知根返回 ErrNotFound；根未配置物理路径返回 ErrInvalidArgument（此时无法读文件，
// 但引用查询仍可用，故只影响刷新路径）。
func (s *Service) rootPath(rootTag string) (string, error) {
	tag := strings.TrimSpace(rootTag)
	if tag == "" {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "根 tag 不能为空")
	}

	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, r := range s.roots {
		if r.Tag != tag {
			continue
		}
		if strings.TrimSpace(r.Path) == "" {
			return "", logging.NewAppError(logging.ErrInvalidArgument,
				"根 "+tag+" 未配置物理路径，无法解析引用")
		}
		return r.Path, nil
	}
	return "", logging.NewAppError(logging.ErrNotFound, "未知的根 tag: "+tag)
}
