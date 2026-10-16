package com.yunx.app

import com.sun.net.httpserver.HttpServer
import com.yunx.app.data.network.BaiduApi
import com.yunx.app.data.repository.BaiduResolveRepository
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.http.URLProtocol
import io.ktor.http.Url
import kotlinx.coroutines.runBlocking
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BaiduShareFlowTest {
    @Test
    fun publicSharesStripTheTypePrefixAndPreserveRealListErrors() = runBlocking {
        val id = "sample-Share_ID12345678"
        val verifies = AtomicInteger()
        val listed = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val url = Url("http://127.0.0.1" + exchange.requestURI)
            if (url.encodedPath == "/share/verify") verifies.incrementAndGet()
            val valid = url.parameters["shorturl"] == id && url.parameters["root"] == "1" &&
                exchange.requestHeaders.getFirst("Referer") == "https://pan.baidu.com/s/1$id"
            val response = if (valid) {
                listed.incrementAndGet()
                """{"errno":0,"share_id":"123","uk":"456","list":[{"fs_id":"789","server_filename":"fixture.zip","path":"/fixture.zip","size":100,"isdir":0}]}"""
            } else if (url.parameters["shorturl"] == "unknown") {
                """{"errno":9999,"errmsg":"fixture service error"}"""
            } else """{"errno":140,"show_msg":"啊哦，链接出错了"}"""
            val bytes = response.encodeToByteArray()
            exchange.responseHeaders.set("Content-Type", "application/json; charset=utf-8")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
            exchange.close()
        }
        server.start()
        val client = HttpClient(CIO) {
            install(createClientPlugin("BaiduShareFixture") {
                onRequest { request, _ ->
                    request.url.protocol = URLProtocol.HTTP
                    request.url.host = "127.0.0.1"
                    request.url.port = server.address.port
                }
            })
        }
        try {
            val api = BaiduApi { client }
            val repository = BaiduResolveRepository(api)
            for (link in listOf("https://pan.baidu.com/s/1$id", "https://pan.baidu.com/s/5$id",
                "https://pan.baidu.com/wap/link?surl=5$id#/home/%2F/%2F", "https://pan.baidu.com/wap/link?surl=1$id")) {
                val session = repository.createSession(link, null, "").getOrThrow()
                assertEquals(id, session.shareId)
                val files = repository.listFiles(session, "/", "").getOrThrow()
                assertEquals("789", files.single().fid)
            }
            assertEquals(4, listed.get())
            assertEquals(0, verifies.get(), "Public shares must not require or invent an extraction code")
            for ((badId, message) in listOf("missing" to "啊哦，链接出错了", "unknown" to "fixture service error")) {
                val error = runCatching { api.listShare(badId, "", "/", "") }.exceptionOrNull()
                assertTrue(error?.message.orEmpty().contains(message))
                assertFalse(error?.message.orEmpty().contains("提取码"))
            }
        } finally { client.close(); server.stop(0) }
    }
}
