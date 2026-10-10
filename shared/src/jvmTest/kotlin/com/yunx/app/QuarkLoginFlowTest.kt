package com.yunx.app

import com.sun.net.httpserver.HttpServer
import com.yunx.app.data.db.QuarkAccountDao
import com.yunx.app.data.db.QuarkAccountEntity
import com.yunx.app.data.network.QuarkApi
import com.yunx.app.data.network.QuarkConstants
import com.yunx.app.data.network.DomainCookiesStorage
import com.yunx.app.data.repository.QuarkAccountRepository
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.client.plugins.cookies.HttpCookies
import io.ktor.http.URLProtocol
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class QuarkLoginFlowTest {
    @Test
    fun guestCookiesCannotBeSavedAndVerifiedCookiesReachTheDrive() = runBlocking {
        val state = MutableStateFlow<QuarkAccountEntity?>(QuarkAccountEntity(cookie = "previous-session"))
        val dao = object : QuarkAccountDao {
            override fun observeAccount() = state
            override suspend fun getAccount() = state.value
            override suspend fun upsert(account: QuarkAccountEntity) { state.value = account }
            override suspend fun clear() { state.value = null }
        }
        val requests = AtomicInteger()
        val nicknames = AtomicInteger()
        val rotatedCookieUsed = AtomicBoolean()
        val refererUsed = AtomicBoolean()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            requests.incrementAndGet()
            val cookie = exchange.requestHeaders.getFirst("Cookie").orEmpty()
            val accountInfo = exchange.requestURI.path == "/account/info"
            val authorized = cookie.contains("__pus=authenticated")
            val httpStatus = if (cookie.contains("__pus=http-error")) 503 else 200
            val body = when {
                accountInfo -> {
                    nicknames.incrementAndGet()
                    rotatedCookieUsed.set(cookie.contains("__puus=rotated"))
                    """{"success":true,"data":{"nickname":"fixture-user"}}"""
                }
                authorized -> {
                    refererUsed.set(exchange.requestHeaders.getFirst("Referer") == "https://pan.quark.cn/")
                    exchange.responseHeaders.add("Set-Cookie", "__puus=rotated; Path=/; HttpOnly")
                    // An empty personal drive is still an authenticated success.
                    """{"status":200,"data":{"list":[]}}"""
                }
                httpStatus == 503 -> """{"status":200,"data":{"list":[]}}"""
                else -> {
                    exchange.responseHeaders.add("Set-Cookie", "__puus=guest-updated; Path=/")
                    """{"status":401,"message":"require login [guest]"}"""
                }
            }.encodeToByteArray()
            exchange.responseHeaders.set("Content-Type", "application/json")
            exchange.sendResponseHeaders(httpStatus, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
            exchange.close()
        }
        server.start()
        val client = HttpClient(CIO) {
            install(createClientPlugin("LocalQuarkFixture") {
                onRequest { request, _ ->
                    request.url.protocol = URLProtocol.HTTP
                    request.url.host = "127.0.0.1"
                    request.url.port = server.address.port
                }
            })
            // Route before HttpCookies captures the URL, preserving the production cookie pipeline.
            install(HttpCookies) { storage = DomainCookiesStorage() }
        }
        try {
            val api = QuarkApi { client }
            val repository = QuarkAccountRepository(dao, api)
            for (invalid in listOf("__pus=; __puus=", "x__pus=a; __puus=b", "__pus=a; __puus=b\nheader")) {
                assertFalse(QuarkConstants.isValidCookie(invalid))
                assertFalse(repository.saveQuarkAccount(invalid))
            }
            assertEquals(0, requests.get())
            assertFalse(repository.saveQuarkAccount("__pus=guest; __puus=intermediate"))
            assertFalse(repository.saveQuarkAccount("__pus=http-error; __puus=intermediate"))
            assertEquals("previous-session", state.value?.cookie)
            assertEquals(0, nicknames.get())
            assertTrue(repository.saveQuarkAccount("__pus=authenticated; __puus=initial"))
            assertEquals("fixture-user", state.value?.nickname)
            val savedCookie = checkNotNull(state.value).cookie
            assertEquals("__pus=authenticated; __puus=rotated", savedCookie)
            assertEquals(1, nicknames.get())
            assertTrue(rotatedCookieUsed.get())
            assertTrue(refererUsed.get())
            assertTrue(api.listCloudFiles("0", savedCookie).isNullOrEmpty())
        } finally {
            client.close()
            server.stop(0)
        }
    }
}
