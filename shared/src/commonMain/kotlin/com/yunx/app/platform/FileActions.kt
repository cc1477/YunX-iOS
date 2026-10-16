package com.yunx.app.platform

/** Present compatible installed apps and system actions for a downloaded file. */
expect suspend fun chooseFileApp(path: String): Boolean
