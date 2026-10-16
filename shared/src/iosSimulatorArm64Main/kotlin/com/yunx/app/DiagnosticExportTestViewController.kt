@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.Text
import androidx.compose.ui.window.ComposeUIViewController
import com.yunx.app.platform.*
import com.yunx.app.util.DiagnosticLog
import com.yunx.app.util.LogExporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okio.FileSystem
import okio.Path.Companion.toPath
import platform.Foundation.NSError
import io.ktor.client.engine.darwin.DarwinHttpRequestException
import com.yunx.app.data.network.HttpClients
import com.yunx.app.data.network.DomainCookiesStorage
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import platform.Foundation.NSProcessInfo
import kotlinx.serialization.json.*

/** Simulator-only check of the shipping exporter and UIKit share sheet, with synthetic input. */
fun DiagnosticExportTestViewController() = ComposeUIViewController {
    Text("诊断日志导出测试")
    LaunchedEffect(Unit) {
        delay(1000)
        DiagnosticLog.setEnabled(true)
        val wirePreserved = withContext(Dispatchers.Default) {
            val fixtureUrl = requireNotNull(NSProcessInfo.processInfo.environment["YUNX_COOKIE_TEST_URL"] as? String)
            val client = HttpClients.newSessionClient(storage = DomainCookiesStorage())
            try {
                val original = "__pus=fixture%2Fprincipal%2Bvalue%3D; __puus=fixture+session/value==; marker=part%252Ftail"
                val initial = client.get(fixtureUrl + "initial") { headers.append("Cookie", original) }
                check(initial.status.value == 200)
                check(Json.parseToJsonElement(initial.bodyAsText()).jsonObject["matches"]?.jsonPrimitive?.boolean == true)
                val rotated = client.get(fixtureUrl + "rotated")
                check(rotated.status.value == 200)
                check(Json.parseToJsonElement(rotated.bodyAsText()).jsonObject["matches"]?.jsonPrimitive?.boolean == true)
                true
            } finally { client.close() }
        }
        DiagnosticLog.event(DiagnosticLog.OPERATION, "native_cookie_wire_verified")
        DiagnosticLog.event(DiagnosticLog.OPERATION, "native_export_test")
        DiagnosticLog.event(DiagnosticLog.OPERATION, "privacy_fixture", "Cookie: fixture=native-secret; second=second-secret")
        DiagnosticLog.exception(DiagnosticLog.OPERATION, "native_exception_fixture", IllegalStateException("password=native-secret"))
        DiagnosticLog.exception(DiagnosticLog.NETWORK, "native_network_fixture",
            DarwinHttpRequestException(NSError.errorWithDomain("NSURLErrorDomain", -1009, null)))
        val file = withContext(Dispatchers.Default) {
            requireNotNull(LogExporter.exportDiagnosticToDownloads())
        }
        // The real exporter returns only after UIKit confirms presentation. The key window can
        // change while sharing, so querying its root again is not a reliable presentation check.
        val presented = LogExporter.share(file)
        FileSystem.SYSTEM.write(appCacheDir().toPath() / "diagnostic-export-test.json") {
            writeUtf8("""{"exported":true,"sharePresented":$presented,"cookieWirePreserved":$wirePreserved}""")
        }
        DiagnosticLog.setEnabled(false)
    }
}
