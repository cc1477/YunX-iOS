@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import platform.Foundation.NSBundle
import platform.Foundation.NSURL
import platform.Foundation.NSFileManager
import platform.UIKit.*
import platform.UIKit.UISceneActivationState.UISceneActivationStateForegroundActive
import io.ktor.client.engine.darwin.DarwinHttpRequestException

actual fun diagnosticEnvironment(): String {
    val bundle = NSBundle.mainBundle
    val version = bundle.objectForInfoDictionaryKey("CFBundleShortVersionString") ?: "unknown"
    val build = bundle.objectForInfoDictionaryKey("CFBundleVersion") ?: "unknown"
    return "YunX $version ($build)\n${UIDevice.currentDevice.systemName} ${UIDevice.currentDevice.systemVersion}\n${UIDevice.currentDevice.model}"
}

actual fun diagnosticExceptionDetails(failure: Throwable): String =
    (failure as? DarwinHttpRequestException)?.origin?.let { "errorDomain=" + it.domain + " | nativeCode=" + it.code }.orEmpty()

actual suspend fun shareDiagnosticFile(path: String): Boolean = chooseFileApp(path)

actual suspend fun chooseFileApp(path: String): Boolean = withContext(Dispatchers.Main) {
    if (path.isBlank() || !NSFileManager.defaultManager.fileExistsAtPath(path)) return@withContext false
    val scene = UIApplication.sharedApplication.connectedScenes
        .filterIsInstance<UIWindowScene>()
        .firstOrNull { it.activationState == UISceneActivationStateForegroundActive }
    val window = scene?.windows?.filterIsInstance<UIWindow>()?.firstOrNull { it.isKeyWindow() }
        ?: UIApplication.sharedApplication.keyWindow
    var presenter = window?.rootViewController ?: return@withContext false
    while (presenter.presentedViewController != null) presenter = presenter.presentedViewController!!
    if (presenter.isBeingDismissed() || presenter.isBeingPresented()) return@withContext false
    val sheet = UIActivityViewController(listOf(NSURL.fileURLWithPath(path)), null)
    sheet.popoverPresentationController?.apply {
        sourceView = presenter.view
        sourceRect = presenter.view.bounds
    }
    withTimeoutOrNull(30_000) {
        suspendCancellableCoroutine<Boolean> { continuation ->
            presenter.presentViewController(sheet, animated = true) {
                if (continuation.isActive) continuation.resume(sheet.presentingViewController != null)
            }
        }
    } ?: false
}
