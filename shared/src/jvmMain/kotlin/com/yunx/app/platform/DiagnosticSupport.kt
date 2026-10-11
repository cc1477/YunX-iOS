package com.yunx.app.platform

actual fun diagnosticEnvironment(): String = "YunX JVM test host\nJava ${System.getProperty("java.version")}\n${System.getProperty("os.name")}"
actual suspend fun shareDiagnosticFile(path: String): Boolean = false
