@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.yunx.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.yunx.app.ui.components.AppScaffold
import com.yunx.app.ui.MainScreen
import com.yunx.app.ui.navigation.MainTab
import com.yunx.app.ui.platform.UiPreferences
import com.yunx.app.ui.login.CookieLoginScreen
import com.yunx.app.ui.screens.SupportScreen
import com.yunx.app.ui.screens.QuarkAccountSheet
import com.yunx.app.ui.screens.SaveStepScaffold
import com.yunx.app.data.db.QuarkAccountEntity
import com.yunx.app.ui.theme.ComposeEmptyActivityTheme
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.coroutines.EmptyCoroutineContext

/** Uses the actual shared Compose layout engine, with no browser or mock HTML. */
class UiLayoutTest {
    @Test
    fun freshInstallOpensTheSameHomeAsExistingInstall() {
        val prefs = UiPreferences()
        val previous = prefs.getBoolean("onboarding_shown", false)
        try {
            for ((width, height, scale) in listOf(Triple(320, 568, 1f), Triple(375, 667, 1.8f), Triple(667, 375, 2f))) {
                for (dark in listOf(false, true)) {
                    prefs.putBoolean("onboarding_shown", false)
                    val fresh = render("startup-fresh-${width}x$height-$scale-$dark", width, height, scale, dark) { MainScreen() }
                    prefs.putBoolean("onboarding_shown", true)
                    val existing = render("startup-existing-${width}x$height-$scale-$dark", width, height, scale, dark) { MainScreen() }
                    assertTrue(fresh.contentEquals(existing), "Legacy onboarding preference must not change the default home")
                }
            }
        } finally { prefs.putBoolean("onboarding_shown", previous) }
    }

    @Test
    fun safeAreaIsAppliedOnceAndTabletContentStaysReadable() {
        var bounds = Rect.Zero
        render("insets", 375, 667) {
            AppScaffold(contentWindowInsets = WindowInsets(left = 20, top = 59, right = 20, bottom = 34)) {
                AppScaffold {
                    Box(Modifier.fillMaxSize().onGloballyPositioned { bounds = it.boundsInRoot() })
                }
            }
        }
        assertEquals(Rect(20f, 59f, 355f, 633f), bounds)
        render("tablet-width", 1194, 834) {
            AppScaffold {
                Box(Modifier.fillMaxSize().onGloballyPositioned { bounds = it.boundsInRoot() })
            }
        }
        assertEquals(840f, bounds.width)
        assertEquals(177f, bounds.left)
    }

    @Test
    fun sharedPagesRenderAtPhoneLandscapeAndTabletTextSizes() {
        val scenarios = listOf(
            Triple(375, 667, 1f), Triple(320, 568, 1f),
            Triple(667, 375, 1f), Triple(375, 667, 2f),
            Triple(667, 375, 2f), Triple(1194, 834, 1f),
            Triple(834, 1194, 2f)
        )
        for ((width, height, scale) in scenarios) {
            for (dark in listOf(false, true)) {
                val name = "${width}x$height-text$scale-${if (dark) "dark" else "light"}"
                render("login-$name", width, height, scale, dark) {
                    CookieLoginScreen("夸克网盘登录", "https://pan.quark.cn", {}, {}, validateAndSave = { false })
                }
                render("support-$name", width, height, scale, dark) { SupportScreen({}) }
            }
        }
    }

    @Test
    fun mainTabsRenderWithCompactAndExpandedNavigation() {
        for ((width, height, scale) in listOf(Triple(320, 568, 1f), Triple(375, 667, 1.8f), Triple(667, 375, 2f), Triple(834, 1194, 1f))) {
            for (dark in listOf(false, true)) {
                for (tab in MainTab.values()) {
                    render("main-${tab.name}-${width}x$height-text$scale-${if (dark) "dark" else "light"}", width, height, scale, dark) {
                        MainScreen(openTab = tab)
                    }
                }
            }
        }
        render("main-reduced-motion", 667, 375, 2f, reducedMotion = true) {
            MainScreen(openTab = MainTab.Drive)
        }
    }

    @Test
    fun accountAndDirectorySheetsRenderWithLongContent() {
        for ((width, height, scale) in listOf(Triple(375, 667, 1f), Triple(667, 375, 2f))) {
            render("account-${width}x$height-text$scale", width, height, scale) {
                QuarkAccountSheet(
                    QuarkAccountEntity(cookie = "sample=value;".repeat(30), nickname = "很长的网盘账号名称用于检查换行"), {}, {}
                )
            }
            render("directory-${width}x$height-text$scale", width, height, scale) {
                androidx.compose.material3.ModalBottomSheet(
                    onDismissRequest = {},
                    sheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true)
                ) {
                    SaveStepScaffold("转存到网盘", "一个很长的待转存文件名.zip", {}) {
                        Column(Modifier.padding(24.dp)) {
                            androidx.compose.foundation.lazy.LazyColumn(Modifier.heightIn(max = 280.dp)) {
                                items(20) { androidx.compose.material3.Text("目录 $it") }
                            }
                            androidx.compose.material3.Button(onClick = {}) { androidx.compose.material3.Text("转存到此目录") }
                        }
                    }
                }
            }
        }
    }

    private fun render(
        name: String, width: Int, height: Int, scale: Float = 1f, dark: Boolean = false, reducedMotion: Boolean = false,
        content: @Composable () -> Unit
    ): ByteArray {
        var rendered = byteArrayOf()
        javax.swing.SwingUtilities.invokeAndWait {
            val motionContext = if (reducedMotion) object : MotionDurationScale {
                override val scaleFactor = 0f
            } else EmptyCoroutineContext
            val scene = ImageComposeScene(width, height, Density(1f, scale), coroutineContext = motionContext) {
                ComposeEmptyActivityTheme(darkTheme = dark) { content() }
            }
            try {
                // Effects can start an animation after the first frame; settle it before capture.
                for (frame in 0L..3L) scene.render(frame * 1_000_000_000L).close()
                scene.render(4_000_000_000L).use { image ->
                    assertEquals(width, image.width)
                    assertEquals(height, image.height)
                    val bytes = image.encodeToData(EncodedImageFormat.PNG)!!.use { it.bytes }
                    rendered = bytes
                    assertTrue(bytes.size > 100)
                    File("build/ui-layout/$name.png").apply { parentFile.mkdirs(); writeBytes(bytes) }
                }
            } finally { scene.close() }
        }
        return rendered
    }
}
