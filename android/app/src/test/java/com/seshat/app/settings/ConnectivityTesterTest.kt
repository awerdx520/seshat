package com.seshat.app.settings

import com.seshat.app.sync.SeshatConfig
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/** [ConnectivityTester] 结果分支单测（MockWebServer）。 */
class ConnectivityTesterTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        runCatching { server.shutdown() }
    }

    /** 用本机 MockWebServer 地址构造配置（服务端地址不带结尾斜杠）。 */
    private fun config(): SeshatConfig =
        SeshatConfig(serverUrl = "http://127.0.0.1:${server.port}", token = "t")

    @Test
    fun okOn200() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))
        val result = ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test()
        assertEquals(ConnectivityResult.Ok, result)

        // 探针请求形态：路径 + 查询参数 + Bearer 认证头。
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals(
            "/api/annotations?document_id=${ConnectivityTester.PROBE_DOCUMENT_ID}",
            request.path,
        )
        assertEquals("Bearer t", request.getHeader("Authorization"))
    }

    @Test
    fun okOn204() {
        server.enqueue(MockResponse().setResponseCode(204))
        assertEquals(ConnectivityResult.Ok, ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test())
    }

    @Test
    fun unauthorizedOn401() {
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(
            ConnectivityResult.Unauthorized,
            ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test(),
        )
    }

    @Test
    fun unauthorizedOn403() {
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(
            ConnectivityResult.Unauthorized,
            ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test(),
        )
    }

    @Test
    fun serverErrorOn500() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(
            ConnectivityResult.ServerError(500),
            ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test(),
        )
    }

    @Test
    fun serverErrorOn404() {
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(
            ConnectivityResult.ServerError(404),
            ConnectivityTester(config(), OkHttpClient(), requireHttps = false).test(),
        )
    }

    @Test
    fun unreachableOnNoResponse() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val client = OkHttpClient.Builder()
            .connectTimeout(200, TimeUnit.MILLISECONDS)
            .readTimeout(200, TimeUnit.MILLISECONDS)
            .build()
        val result = ConnectivityTester(config(), client, requireHttps = false).test()
        assertTrue(result is ConnectivityResult.Unreachable)
    }

    @Test
    fun unreachableOnClosedServer() {
        val config = config()
        server.shutdown()
        val result = ConnectivityTester(config, OkHttpClient(), requireHttps = false).test()
        assertTrue(result is ConnectivityResult.Unreachable)
    }

    @Test
    fun illegalTokenCharsDoNotCrash() {
        // 令牌含换行：OkHttp 构造请求头会抛 IllegalArgumentException，必须被兜住为 Unreachable。
        val illegal = SeshatConfig(
            serverUrl = "http://127.0.0.1:${server.port}",
            token = "abc\ndef",
        )
        val result = ConnectivityTester(illegal, OkHttpClient(), requireHttps = false).test()
        assertTrue(result is ConnectivityResult.Unreachable)
    }

    @Test
    fun cleartextRejectedByDefault() {
        // 默认 requireHttps = true：明文 http 地址在发请求前即被拒绝。
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))
        val result = ConnectivityTester(config(), OkHttpClient()).test()
        assertTrue(result is ConnectivityResult.Unreachable)
        // 请求未发出的旁证：MockWebServer 没收到任何请求
        assertEquals(0, server.requestCount)
    }
}
