package com.yunx.app

import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController
import platform.Foundation.NSBundle
import com.yunx.app.data.update.UpdateChecker

/** Exported to Swift as MainViewControllerKt.MainViewController(). */
fun MainViewController(): UIViewController {
    val bundle = NSBundle.mainBundle
    UpdateChecker.installedVersion = bundle.objectForInfoDictionaryKey("CFBundleShortVersionString") as? String ?: "0.0.0"
    UpdateChecker.installedBuild = (bundle.objectForInfoDictionaryKey("CFBundleVersion") as? String)?.toIntOrNull() ?: 0
    return ComposeUIViewController { App() }
}
