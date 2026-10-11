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
import platform.UIKit.UIApplication
import platform.UIKit.UIActivityViewController

/** Simulator-only check of the shipping exporter and UIKit share sheet, with synthetic input. */
fun DiagnosticExportTestViewController() = ComposeUIViewController {
    Text("诊断日志导出测试")
    LaunchedEffect(Unit) {
        delay(1000)
        DiagnosticLog.setEnabled(true)
        DiagnosticLog.event(DiagnosticLog.OPERATION, "native_export_test")
        DiagnosticLog.event(DiagnosticLog.OPERATION, "privacy_fixture", "Cookie: fixture=native-secret; second=second-secret")
        DiagnosticLog.exception(DiagnosticLog.OPERATION, "native_exception_fixture", IllegalStateException("password=native-secret"))
        val file = withContext(Dispatchers.Default) {
            requireNotNull(LogExporter.exportDiagnosticToDownloads())
        }
        val requested = LogExporter.share(file)
        delay(1000)
        val presented = UIApplication.sharedApplication.keyWindow?.rootViewController?.presentedViewController is UIActivityViewController
        FileSystem.SYSTEM.write(appCacheDir().toPath() / "diagnostic-export-test.json") {
            writeUtf8("""{"exported":true,"shareRequested":$requested,"sharePresented":$presented}""")
        }
        DiagnosticLog.setEnabled(false)
    }
}
