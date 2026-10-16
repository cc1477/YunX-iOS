package com.yunx.app

import com.yunx.app.platform.SharedLinkInbox
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SharedLinkInboxTest {
    @Test fun sharesWaitForUiAndOlderConsumptionCannotDropNewerShare() {
        val first = "https://pan.baidu.com/s/1sample 提取码: abcd"
        val next = "https://pan.quark.cn/s/sample"
        try {
            assertTrue(SharedLinkInbox.submit(first))
            assertEquals(first, SharedLinkInbox.text.value)
            assertTrue(SharedLinkInbox.submit(next))
            SharedLinkInbox.consume(first)
            assertEquals(next, SharedLinkInbox.text.value)
            SharedLinkInbox.consume(next)
            assertNull(SharedLinkInbox.text.value)
            assertTrue(SharedLinkInbox.submit(next))
            assertEquals(next, SharedLinkInbox.text.value)
        } finally { SharedLinkInbox.text.value?.let(SharedLinkInbox::consume) }
    }

    @Test fun invalidInputDoesNotOverwritePendingShare() {
        val text = "https://fixture.invalid/share"
        try {
            SharedLinkInbox.submit(text)
            assertFalse(SharedLinkInbox.submit("  "))
            assertFalse(SharedLinkInbox.submit("x".repeat(65_537)))
            assertEquals(text, SharedLinkInbox.text.value)
        } finally { SharedLinkInbox.consume(text) }
    }
}
