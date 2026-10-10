package com.yunx.app

import com.sun.net.httpserver.HttpServer
import com.yunx.app.data.download.ChunkDownloader
import com.yunx.app.data.network.LanzouApi
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.http.URLProtocol
import kotlinx.coroutines.runBlocking
import okio.Path.Companion.toPath
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LanzouDownloadFlowTest {
    @Test
    fun nodeCookieRetryAndFileDownloadShareTheVerifiedSession() = runBlocking {
        val bytes = ByteArray(4096) { (it % 251).toByte() }
        val verifiedHeads = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val cookie = exchange.requestHeaders.getFirst("Cookie").orEmpty()
            val verified = cookie.contains("down_ip=1") && cookie.contains("acw_sc__v2=")
            var contentType = "text/html; charset=utf-8"
            val body = when (exchange.requestURI.path) {
                "/share" -> "<title>fixture</title><script>var dynamic_sign='';var dynamic_sign='fixture-sign';data:{'action':'downprocess','sign':dynamic_sign};</script><a href='ajaxfile.php?file=123'>file</a>".encodeToByteArray()
                "/ajaxfile.php" -> {
                    val form = exchange.requestBody.readAllBytes().decodeToString()
                    contentType = "application/json"
                    if (form.contains("sign=fixture-sign")) "{\"zt\":1,\"dom\":\"https://download.lanzou.example\",\"url\":\"fixture\"}".encodeToByteArray()
                    else "{\"zt\":0}".encodeToByteArray()
                }
                "/file/fixture" -> if (verified) {
                    if (exchange.requestMethod == "HEAD") verifiedHeads.incrementAndGet()
                    contentType = "application/octet-stream"
                    bytes
                } else "<script>var arg1='0123456789ABCDEF0123456789ABCDEF01234567';</script>".encodeToByteArray()
                else -> byteArrayOf()
            }
            exchange.responseHeaders.set("Content-Type", contentType)
            exchange.responseHeaders.set("Content-Length", body.size.toString())
            val head = exchange.requestMethod == "HEAD"
            exchange.sendResponseHeaders(200, if (head) -1 else body.size.toLong())
            exchange.responseBody.use { if (!head) it.write(body) }
            exchange.close()
        }
        server.start()
        val client = HttpClient(CIO) {
            install(createClientPlugin("LocalLanzouFixture") {
                onRequest { request, _ ->
                    request.url.protocol = URLProtocol.HTTP
                    request.url.host = "127.0.0.1"
                    request.url.port = server.address.port
                }
            })
        }
        val directory = Files.createTempDirectory("yunx-lanzou-test")
        val output = directory.resolve("fixture.bin")
        try {
            val api = LanzouApi { client }
            val page = api.resolveShare("https://fixture.lanzou.example/share", "fixture-code")
            val link = api.getShareDownloadLink(page, checkNotNull(page.singleFile), "fixture-code")
            assertEquals(1, verifiedHeads.get())
            assertEquals(bytes.size.toLong(), link.size)
            assertTrue(link.guestCookie.contains("acw_sc__v2="))
            assertTrue(ChunkDownloader { client }.downloadFull(1, link.downloadUrl, output.toString().toPath(),
                mapOf("Cookie" to link.guestCookie), link.size) {})
            assertContentEquals(bytes, Files.readAllBytes(output))
        } finally {
            client.close()
            server.stop(0)
            Files.deleteIfExists(output)
            Files.deleteIfExists(directory)
        }
    }
}
