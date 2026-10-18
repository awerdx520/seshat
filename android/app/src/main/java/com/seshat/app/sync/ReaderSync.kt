package com.seshat.app.sync

/**
 * 阅读器同步的装配守卫：只有「有 uid」且「服务端配置齐全」时才返回可用的 [SyncManager]。
 *
 * 任一条件不满足返回 `null`，且**不得调用** [restFactory]——保持「服务端未配置时零网络行为」，
 * 避免离线用户在打开书籍时产生任何连接尝试（省电、无日志噪声、无隐私泄漏）。
 *
 * **为什么先判 uid**：服务端 REST 以 `documents/<uid>/...` 寻址，没有 uid 时 URL 里就没有稳定身份，
 * 进度与批注无法归属到任何远端文档——即便强行推送，也只会生成再也读不回来的孤儿数据
 * （本地键退回内容哈希或 uri，远端无对应 uid）。因此无 uid 视为「本机离线阅读」，完全跳过同步。
 *
 * @param uid 服务端文档 uid；`null` 或空白表示未登记（离线打开），直接返回 `null`。
 * @param config 服务端连接配置；`null`（地址或令牌缺失，见 `SettingsStore.toConfig`）时返回 `null`。
 * @param restFactory 由配置构造 REST 客户端；**仅在两个守卫都通过后**才会被调用一次。
 * @param store 本地进度/批注存储（epub / pdf 各自的适配实现）。
 * @param mapper 本地模型与服务端 DTO 的字段映射。
 * @return 装配好的同步管理器；守卫不通过时为 `null`。
 */
internal fun <P, A> createReaderSync(
    uid: String?,
    config: SeshatConfig?,
    restFactory: (SeshatConfig) -> RestSyncApi,
    store: LocalSyncStore<P, A>,
    mapper: SyncMapper<P, A>,
): SyncManager<P, A>? {
    if (uid.isNullOrBlank()) return null
    if (config == null) return null
    return SyncManager(restFactory(config), store, mapper)
}
