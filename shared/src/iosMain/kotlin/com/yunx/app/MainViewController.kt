package com.yunx.app

import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

/** Exported to Swift as MainViewControllerKt.MainViewController(). */
fun MainViewController(): UIViewController = ComposeUIViewController { App() }
