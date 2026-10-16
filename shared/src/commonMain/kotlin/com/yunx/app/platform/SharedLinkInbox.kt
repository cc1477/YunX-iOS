package com.yunx.app.platform

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Holds a native share until Compose is ready, including a cold launch. */
object SharedLinkInbox {
    private val pending = MutableStateFlow<String?>(null)
    val text = pending.asStateFlow()

    fun submit(text: String): Boolean {
        if (text.isBlank() || text.length > 65_536) return false
        pending.value = text
        return true
    }

    fun consume(text: String) { pending.compareAndSet(text, null) }
}
