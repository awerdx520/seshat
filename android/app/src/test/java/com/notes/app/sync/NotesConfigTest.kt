package com.notes.app.sync

import org.junit.Assert.assertEquals
import org.junit.Test

/** NotesConfig URL 拼接与基本约定的单元测试。 */
class NotesConfigTest {

    @Test
    fun baseUrlTrimsTrailingSlash() {
        val c = NotesConfig(serverUrl = "https://notes.example.com/", token = "t")
        assertEquals("https://notes.example.com", c.baseUrl)
        assertEquals("https://notes.example.com/api", c.apiBase)
        assertEquals("https://notes.example.com/dav", c.davBase)
    }

    @Test
    fun davUrlJoinsRelativePath() {
        val c = NotesConfig(serverUrl = "http://host:8080", token = "t")
        assertEquals("http://host:8080/dav/notes/a.org", c.davUrl("notes/a.org"))
        assertEquals("http://host:8080/dav/notes/a.org", c.davUrl("/notes/a.org"))
    }

    @Test
    fun davUrlRootReturnsBase() {
        val c = NotesConfig(serverUrl = "http://host:8080/", token = "t")
        assertEquals("http://host:8080/dav", c.davUrl("/"))
        assertEquals("http://host:8080/dav", c.davUrl(""))
    }

    @Test
    fun remoteDirHasDefault() {
        val c = NotesConfig(serverUrl = "http://host", token = "t")
        assertEquals("/", c.remoteDir)
    }
}
