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

/** Simulator-only check of the shipping exporter and UIKit share sheet, with synthetic input. */
fun DiagnosticExportTestViewController() = ComposeUIViewController {
    Text("诊断日志导出测试")
    LaunchedEffect(Unit) {
        delay(1000)
        DiagnosticLog.setEnabled(true)
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
            writeUtf8("""{"exported":true,"sharePresented":$presented}""")
        }
        DiagnosticLog.setEnabled(false)
    }
}
