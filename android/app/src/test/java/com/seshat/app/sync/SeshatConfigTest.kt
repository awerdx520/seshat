package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Test

/** SeshatConfig URL 拼接与基本约定的单元测试。 */
class SeshatConfigTest {

    @Test
    fun baseUrlTrimsTrailingSlash() {
        val c = SeshatConfig(serverUrl = "https://seshat.example.com/", token = "t")
        assertEquals("https://seshat.example.com", c.baseUrl)
        assertEquals("https://seshat.example.com/api", c.apiBase)
        assertEquals("https://seshat.example.com/dav", c.davBase)
    }

    @Test
    fun davUrlJoinsRelativePath() {
        val c = SeshatConfig(serverUrl = "http://host:8080", token = "t")
        assertEquals("http://host:8080/dav/seshat/a.org", c.davUrl("seshat/a.org"))
        assertEquals("http://host:8080/dav/seshat/a.org", c.davUrl("/seshat/a.org"))
    }

    @Test
    fun davUrlRootReturnsBase() {
        val c = SeshatConfig(serverUrl = "http://host:8080/", token = "t")
        assertEquals("http://host:8080/dav", c.davUrl("/"))
        assertEquals("http://host:8080/dav", c.davUrl(""))
    }

    @Test
    fun remoteDirHasDefault() {
        val c = SeshatConfig(serverUrl = "http://host", token = "t")
        assertEquals("/", c.remoteDir)
    }
}
