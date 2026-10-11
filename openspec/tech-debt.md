# 技术债

记录已知技术债与待办。

## SQLCipher 降级（M0.4，2026-10-11）
- 现象：系统未安装 libsqlcipher（pkg-config 探测 NOT found），无法使用 CGO 绑定 github.com/mutecomm/go-sqlcipher。
- 现状：DB 层暂用纯 Go 驱动 modernc.org/sqlite（无加密），Open 的 key 参数保留但被忽略并打降级告警。
- 兜底：静态加密依赖磁盘 LUKS；DB 层加密待部署阶段启用。
- 待办：部署时安装 libsqlcipher-dev → 切换 go-sqlcipher → 补「错误 key 打开失败」加密测试。
