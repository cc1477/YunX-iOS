@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import platform.Foundation.NSBundle
import platform.Foundation.NSURL
import platform.UIKit.*

actual fun diagnosticEnvironment(): String {
    val bundle = NSBundle.mainBundle
    val version = bundle.objectForInfoDictionaryKey("CFBundleShortVersionString") ?: "unknown"
    val build = bundle.objectForInfoDictionaryKey("CFBundleVersion") ?: "unknown"
    return "YunX $version ($build)\n${UIDevice.currentDevice.systemName} ${UIDevice.currentDevice.systemVersion}\n${UIDevice.currentDevice.model}"
}

actual suspend fun shareDiagnosticFile(path: String): Boolean = withContext(Dispatchers.Main) {
    var presenter = UIApplication.sharedApplication.keyWindow?.rootViewController ?: return@withContext false
    while (presenter.presentedViewController != null) presenter = presenter.presentedViewController!!
    if (presenter.isBeingDismissed() || presenter.isBeingPresented()) return@withContext false
    val sheet = UIActivityViewController(listOf(NSURL.fileURLWithPath(path)), null)
    sheet.popoverPresentationController?.apply {
        sourceView = presenter.view
        sourceRect = presenter.view.bounds
    }
    presenter.presentViewController(sheet, animated = true, completion = null)
    true
}
