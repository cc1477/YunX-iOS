package com.yunx.app.platform

/** No device identifier or account data. */
expect fun diagnosticEnvironment(): String
expect fun diagnosticExceptionDetails(failure: Throwable): String
expect suspend fun shareDiagnosticFile(path: String): Boolean
