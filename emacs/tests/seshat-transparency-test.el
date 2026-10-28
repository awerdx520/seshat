;;; seshat-transparency-test.el --- ERT tests for Emacs-side transparency  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 「装上 seshat 之后 Emacs 仍像没装一样」的自动化护栏（M8-C 的 T5 / D6）。
;;
;; 断言方式是**加载后白名单式反向断言**：在模块**已加载**的前提下断言
;; 「不该出现的东西不出现」。刻意不用「加载前 / 加载后」差分——
;; ① 共享 ERT 单进程里模块早已 `require' 完成，而 `require' 幂等 → 差分恒空
;;    → 断言恒真（假绿）；
;; ② `seshat-reading--take-over-auto-mode-alist' 是就地改写，第二次执行零效果，
;;    同样测不出东西。
;;
;; 覆盖的六项（每项至少一例；第 4 项两例）：
;;   1. `auto-mode-alist' 中 `.org' 命中的 mode 不是 seshat 系（按 alist 的真实
;;      匹配方式 `assoc-default' + `string-match' 取值，不假设条目字面形态）；
;;   2. `dired-mode-map' **自身**这棵树里没有绑定到 `seshat-' 前缀命令的键
;;      （用 `map-keymap' 递归自身及其前缀子 keymap；不用按命令反查按键的查询
;;      函数，那类函数会连带搜索父 keymap 链与 `global-map'，无法限定范围）；
;;   3. `after-save-hook' 与 `after-change-major-mode-hook' 中没有 symbol 名以
;;      `seshat-' 开头的函数（元素可能是 `t'、lambda、`(FN . ARGS)' 形式，
;;      探测函数要安全跳过非符号元素）；
;;   4. 「被 advice 的函数名集合」⊆ 白名单（白名单的每次变更都是侵入评审点）；
;;   5. 实际打开 `.org' 得到的 `major-mode' 不是 seshat 系（第 1 项断言 alist
;;      事实，本项断言实际行为）；
;;   6. `seshat-library-mode' 未在 `auto-mode-alist' 中注册任何条目。
;;
;; 第 4 项的关键实现细节：`advice--p' 接受的是**函数对象**，不是符号。对符号
;; 直接调用恒返回 nil，会让集合恒空、断言恒真（假绿）。因此必须先取
;; `(symbol-function SYM)' 再交给 `advice--p'。
;;
;; 另有三个「反向自我验证」用例：把假侵入塞进临时上下文，探测器必须报警。
;; 它们证明断言不是恒定通过（「怎么写都通过」的断言等于没测）。advice 那一例
;; 的清理必须包在 `unwind-protect' 内——断言失败时也要摘掉临时 advice，否则
;; 残留会污染同进程后续用例（ERT 一个进程跑同一个文件内的全部用例）。
;;
;; 白名单里除了 reader 包既有的 `save-place-to-alist' 之外，还必须含
;; `pcase--mutually-exclusive-p'：它由 **stock Emacs 的 `cl-macs.el'** 在
;; `cl-lib' 加载时加上 advice（`cl--pcase-mutually-exclusive-p'），与 seshat
;; 无关，装不装 seshat 都存在。把它当成基线而非「侵入」是白名单的正确口径：
;; 白名单只收录「加载这些模块后确实出现、且已评审过的 advice」。
;;
;; 全部用例**不触网**、不读写用户真实状态库（`~/.local/share/seshat/'）、
;; 不依赖运行中的 Emacs，`emacs -Q --batch' 即可跑通。需要的 `-L'：
;; 仓库内 `emacs' 与 `emacs/seshat-reader'（reader 包），以及第三方依赖
;; `gt' / `pdd' / `posframe' / `etaf' / `etaf/lisp' / `etaf-ui' / `ebox' /
;; `ebox/lisp' / `ecss' / `ecss/lisp' / `markdown-mode' / `visual-fill-column'。

;;; Code:

(require 'ert)
(require 'seq)
(require 'nadvice)
;; reader 包与项目层：本文件断言的是「这几个模块都加载完之后」的全局状态，
;; 因此 require 一律顶层硬依赖（缺 `-L' 就必须报错，不得静默 skip）。
(require 'seshat-reading)
(require 'seshat-sync)
(require 'seshat-state)
;; `seshat-library' 提供 `seshat-library-mode'：第 6 项要断言它「已定义但没注册
;; `auto-mode-alist'」，第 5 项与禁止集也要按该符号判定。T2 已交付，硬依赖。
(require 'seshat-library)
(require 'dired)
;; `seshat-reader-saveplace' 属 vendored reader 包，提供 `save-place-to-alist'
;; 的既有 advice（白名单里的「已知侵入」）。软 require：它缺失时白名单断言
;; 依然成立（集合更小），只是覆盖不到那条既有侵入；有它时断言才真正有效。
(require 'seshat-reader-saveplace nil t)

;;; 白名单与探测器

(defconst seshat-transparency-test--seshat-org-modes
  '(seshat-reading-mode seshat-reader-mode seshat-library-mode)
  "不应接管 `.org' 的 seshat 系 major mode 符号列表.")
;; 这里**不**按 `fboundp' 过滤：`(memq MAJOR-MODE FORBIDDEN)' 比对的是符号，
;; 不需要该 mode 已定义就完全可判定；而 `seshat-library-mode' 在 T2 已交付，
;; 本文件也已顶层硬 require `seshat-library'，因此这一个是**固定包含**的——
;; 既不给它留「未实现所以查不到」的豁免，也不动态裁剪禁止集。

(defconst seshat-transparency-test--advice-whitelist
  '(save-place-to-alist pcase--mutually-exclusive-p)
  "允许被 advice 的函数名白名单（按被 advice 的函数名，不按 advice 函数名）.
两项来源不同，都必须在此显式登记：

- `save-place-to-alist'：reader 包 `seshat-reader-saveplace' 的既有 advice
  （vendored 行为，非本计划引入）；
- `pcase--mutually-exclusive-p'：**stock Emacs** 的 `cl-macs' 在 `cl-lib'
  加载时加的 advice（`cl--pcase-mutually-exclusive-p'），与 seshat 无关。

新增任何 advice 都必须先更新本白名单——白名单的变更本身即侵入评审点：断言
失败时先问「为什么要 advice 第三方函数」，而不是直接加白名单。")

(defun seshat-transparency-test--org-mode-from-alist ()
  "按 `auto-mode-alist' 的真实匹配方式取 \"x.org\" 命中的 mode.
用 `assoc-default' + `string-match'（与 `set-auto-mode' 同法），因此不依赖
条目是否字面写成 \"\\\\.org\\\\'\"。"
  (assoc-default "x.org" auto-mode-alist #'string-match))

(defun seshat-transparency-test--seshat-mode-p (mode)
  "MODE 是否为 `seshat-transparency-test--seshat-org-modes' 中的符号."
  (and (symbolp mode)
       (memq mode seshat-transparency-test--seshat-org-modes)
       mode))

(defun seshat-transparency-test--library-mode-alist-entries ()
  "返回 `auto-mode-alist' 中 cdr 为 `seshat-library-mode' 的条目."
  (seq-filter (lambda (entry) (eq (cdr entry) 'seshat-library-mode))
              auto-mode-alist))

(defun seshat-transparency-test--keymap-bindings (keymap &optional seen)
  "递归遍历 KEYMAP **自身**这棵树，返回 ((EVENT . CMD) ...).
只走自己这棵树：不跟随 `keymap-parent'、不含 `global-map'、也不含其它
keymap（这正是不能用「按命令反查按键」类查询函数的原因——那类函数会连带
搜索父 keymap 链与 `global-map'，无法限定范围）。

必须递归自己的前缀子 keymap：`map-keymap' 只给出顶层的 `(EVENT . KEYMAP)'
对，\"C-c z\" 这类前缀绑定与 `[remap ...]' 伪事件里的命令都藏在子 keymap
里，只扫顶层会整类漏掉（实测：只扫顶层时，塞进 dired-mode-map 的 \"C-c z\"
前缀绑定查不出来）。
SEEN 是已访问 keymap 列表，防环形引用导致死循环。"
  (let (acc)
    (when (keymapp keymap)
      (map-keymap
       (lambda (event cmd)
         (if (keymapp cmd)
             (unless (memq cmd (cons keymap seen))
               (setq acc (append (seshat-transparency-test--keymap-bindings
                                  cmd (cons keymap seen))
                                 acc)))
           (push (cons event cmd) acc)))
       keymap))
    acc))

(defun seshat-transparency-test--seshat-command-p (cmd)
  "CMD 是否为「symbol 名以 \"seshat-\" 开头的命令」."
  (and (symbolp cmd)
       (string-prefix-p "seshat-" (symbol-name cmd))))

(defun seshat-transparency-test--seshat-bindings (keymap)
  "返回 KEYMAP 自身这棵树中绑定到 seshat 系命令的 (EVENT . CMD) 列表."
  (seq-filter (lambda (pair)
                (seshat-transparency-test--seshat-command-p (cdr pair)))
              (seshat-transparency-test--keymap-bindings keymap)))

(defun seshat-transparency-test--hook-seshat-entries (hook-value)
  "从 HOOK-VALUE 里挑出 symbol 名以 \"seshat-\" 开头的函数.
元素可能是 `t'、lambda/`closure'、byte-code 对象或 `(FN . ARGS)' 形式，
非符号元素一律安全跳过（不报错）；`(FN . ARGS)' 取 FN 判定。"
  (let (hits)
    (dolist (elt hook-value)
      (let ((fn (cond
                 ((symbolp elt) elt)
                 ((consp elt)
                  (and (symbolp (car elt)) (car elt)))
                 (t nil))))
        (when (and fn
                   (not (memq fn '(lambda closure)))
                   (string-prefix-p "seshat-" (symbol-name fn)))
          (push fn hits))))
    (nreverse hits)))

(defun seshat-transparency-test--advised-functions ()
  "遍历 obarray，返回「函数对象被 advice 过」的符号列表.
`advice--p' 接受的是**函数对象**；对符号直接调用恒返回 nil，因此这里必须传
`(symbol-function SYM)'（传符号会得到恒空集合 → 断言恒真的假绿）。"
  (let (acc)
    (mapatoms (lambda (sym)
                (when (advice--p (symbol-function sym))
                  (push sym acc))))
    (sort acc #'string<)))

(defun seshat-transparency-test--advice-offenders ()
  "返回被 advice 但不在 `seshat-transparency-test--advice-whitelist' 的符号."
  (seq-filter (lambda (sym)
                (not (memq sym seshat-transparency-test--advice-whitelist)))
              (seshat-transparency-test--advised-functions)))

;;; 1. `auto-mode-alist' 里的 `.org'

(ert-deftest seshat-transparency-test-org-mode-not-taken-over ()
  "`.org' 在 `auto-mode-alist' 中仍归 `org-mode'，不被 seshat 接管."
  ;; 防的侵入：`seshat-reading--take-over-auto-mode-alist' 若从「只改指向
  ;; `seshat-reader-mode' 的项」扩大成「改所有项」或直接注册 `.org'，用户
  ;; 打开任何笔记都会落进 seshat 的 mode。
  (let ((mode (seshat-transparency-test--org-mode-from-alist)))
    (should (equal mode 'org-mode))
    (should (equal (seshat-transparency-test--seshat-mode-p mode) nil))))

(ert-deftest seshat-transparency-test-alist-detectors-are-sensitive ()
  "反向自我验证：临时塞入 seshat 项时，两个 alist 探测器都必须报警."
  ;; 防的伪保护：若探测器恒返回 nil，上面两例就恒通过。这里把假侵入塞进
  ;; 动态绑定的 `auto-mode-alist'（不改全局值），断言探测器确实能抓到。
  (let ((auto-mode-alist (cons '("\\.org\\'" . seshat-reading-mode)
                               auto-mode-alist)))
    (should (equal (seshat-transparency-test--seshat-mode-p
                    (seshat-transparency-test--org-mode-from-alist))
                   'seshat-reading-mode)))
  (let ((auto-mode-alist (cons '("\\.seshat-library\\'" . seshat-library-mode)
                               auto-mode-alist)))
    (should (equal (seshat-transparency-test--library-mode-alist-entries)
                   '(("\\.seshat-library\\'" . seshat-library-mode))))))

;;; 2. `dired-mode-map'

(ert-deftest seshat-transparency-test-dired-mode-map-has-no-seshat-binding ()
  "`dired-mode-map' 自身不存在绑定到 seshat 系命令的键."
  ;; 防的侵入：在 dired 里塞 `d` / `R` / `C-c ...` 之类的 seshat 命令，或
  ;; 用 `remap' 抢 dired 的改名/删除键——这些都是用户可感知的行为改变。
  (let ((all (seshat-transparency-test--keymap-bindings dired-mode-map))
        (hits (seshat-transparency-test--seshat-bindings dired-mode-map)))
    ;; 先证明遍历真的走到了绑定：空 keymap 上「无命中」是空转。
    (should (> (length all) 10))
    (should (equal hits nil))))

;;; 3. 全局 hook

(ert-deftest seshat-transparency-test-hooks-have-no-seshat-function ()
  "`after-save-hook' 与 `after-change-major-mode-hook' 中无 seshat 全局函数."
  ;; 防的侵入：往保存后 / 换 major mode 后这两个全局 hook 里挂 seshat 函数
  ;; （例如「保存时自动同步」「进 mode 时自动登记」），会让用户任何 buffer
  ;; 的日常操作都触发 seshat 逻辑。
  (should (equal (seshat-transparency-test--hook-seshat-entries
                  after-save-hook)
                 nil))
  (should (equal (seshat-transparency-test--hook-seshat-entries
                  after-change-major-mode-hook)
                 nil)))

(ert-deftest seshat-transparency-test-hook-detector-is-sensitive ()
  "反向自我验证：hook 探测器能识别符号与 `(FN . ARGS)' 两种形态."
  ;; 防的伪保护：真实运行环境里两个 hook 可能为空或只含无关函数，此时
  ;; 「无命中」既可能是干净也可能是探测器坏了。这里用 `let' 绑定的假 hook
  ;; 验证探测器：符号形态与 `(FN . ARGS)' 形态都要被抓到，lambda 与无关符号
  ;; 要被安全跳过（不报错、不误报）。
  (let ((after-save-hook (list #'ignore
                               (lambda () nil)
                               '(seshat-transparency-probe . args)
                               'seshat-transparency-probe)))
    (should (equal (seshat-transparency-test--hook-seshat-entries
                    after-save-hook)
                   '(seshat-transparency-probe seshat-transparency-probe)))))

;;; 4. advice 白名单

(ert-deftest seshat-transparency-test-advice-subset-of-whitelist ()
  "被 advice 的函数集合 ⊆ 白名单（新增 advice 必须显式登记）."
  ;; 防的侵入：悄悄改第三方函数行为（改名、保存、打开文件……）。断言按
  ;; 「被 advice 的函数名」建集合，因此匿名 lambda advice 也被覆盖——它体现
  ;; 在「某个函数名进入集合」这一事实上，不必识别 lambda 的来源。
  (should (equal (seshat-transparency-test--advice-offenders) nil)))

(ert-deftest seshat-transparency-test-advice-detector-catches-new-advice ()
  "反向自我验证：新增一条 advice 后，白名单断言必须失败."
  ;; 防的伪保护：这一项最容易写成恒真——`advice--p' 若被误用于符号而非
  ;; 函数对象，集合恒空、断言恒通过。这里临时给 `ignore' 加 :around advice，
  ;; 断言「集合里出现 ignore 且成为白名单外的侵入」；清理段包在
  ;; `unwind-protect' 内，断言失败也要摘掉，避免污染同进程后续用例。
  (let ((before (seshat-transparency-test--advised-functions)))
    (unwind-protect
        (progn
          (advice-add 'ignore :around #'ignore)
          ;; 扫描器必须看到新加的 advice（集合里出现 ignore）……
          (should (equal (seq-filter (lambda (sym) (eq sym 'ignore))
                                     (seshat-transparency-test--advised-functions))
                         '(ignore)))
          ;; ……并且白名单断言必须把它判为侵入（证明该断言有灵敏度）。
          (should (equal (seshat-transparency-test--advice-offenders)
                         '(ignore))))
      (advice-remove 'ignore #'ignore))
    ;; 清理必须真的生效，否则「污染」会以另一种形式留在同进程里。
    (should (equal (seshat-transparency-test--advised-functions) before))))

;;; 5. 实际打开 `.org'

(ert-deftest seshat-transparency-test-org-buffer-stays-out-of-seshat-mode ()
  "实际按 `.org' 自动定 mode 的 buffer 不进入 seshat 系 major mode."
  ;; 防的侵入：第 1 项只断言 alist 事实，本项断言**实际行为**——若有人用
  ;; `find-file-hook' / `set-auto-mode' advice 或把 `.org' 映射到 seshat mode
  ;; 的派生模式，alist 断言可能仍通过而这里会失败。
  (with-temp-buffer
    (setq buffer-file-name "/tmp/seshat-transparency-probe.org")
    (set-auto-mode)
    (should (equal major-mode 'org-mode))
    ;; `seshat-library-mode' 由 T2 交付且本文件已硬 require `seshat-library'，
    ;; 因此这里不再有「缺实现就跳过」的分支：符号比对覆盖全部三个 seshat 系 mode。
    (should (equal (seshat-transparency-test--seshat-mode-p major-mode) nil))))

;;; 6. `seshat-library-mode' 未注册 `auto-mode-alist'

(ert-deftest seshat-transparency-test-library-mode-not-in-auto-mode-alist ()
  "`seshat-library-mode' 已定义，但 `auto-mode-alist' 中无 cdr 为它的条目."
  ;; 防的侵入：书架 mode 若按扩展名自动进入（例如把 `.seshat' / `.library'
  ;; 之类的名字据为己有），用户打开同名文件会被抢走。
  ;; 原先这里有 `(when (fboundp 'seshat-library-mode) ...)' 守卫：T2 未交付时
  ;; mode 不存在，`default-value' 侧那条复核因此**从未真正执行**（未被校验的
  ;; 断言）。T2 已交付且本文件顶层硬 require `seshat-library'，守卫不再需要，
  ;; 改为断言「mode 必须存在」——实现缺失时直接红，而不是静默跳过。
  (should (fboundp 'seshat-library-mode))
  (should (equal (seshat-transparency-test--library-mode-alist-entries) nil))
  ;; 再从 `default-value' 侧复核一次（防「只在 buffer-local 绑定上看不出」的
  ;; 假绿：当前 buffer 的 `auto-mode-alist' 可能就是一份局部副本）。
  (should (equal (seq-filter (lambda (entry)
                               (eq (cdr entry) 'seshat-library-mode))
                             (default-value 'auto-mode-alist))
                 nil)))

(provide 'seshat-transparency-test)
;;; seshat-transparency-test.el ends here
