package console

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.window.ComposeViewport
import top.yukonga.miuix.kmp.theme.defaultTextStyles

@OptIn(ExperimentalComposeUiApi::class)
fun main() {
    ComposeViewport(viewportContainerId = "composeApp") {
        val resolver = LocalFontFamilyResolver.current
        val scope = rememberCoroutineScope()
        var family by remember { mutableStateOf<FontFamily?>(null) }
        var fontsSettled by remember { mutableStateOf(false) }
        // Outside a KernelSU manager there is no phone to talk to; say so and
        // show a simulation instead of an empty page.
        val controller = remember {
            val backend = if (ksuAvailable()) KsuBackend() else DemoBackend(queryParam("demo"))
            ConsoleController(backend, scope)
        }
        LaunchedEffect(Unit) {
            val loaded = loadConsoleFonts()
            if (loaded != null) {
                // Also the fallback for any text that names no family.
                runCatching { resolver.preload(loaded) }
                family = loaded
            }
            fontsSettled = true
        }
        // Compose text only once the glyphs are there, so nothing is first
        // drawn as empty boxes.
        if (fontsSettled) {
            val styles = remember(family) {
                family?.let { defaultTextStyles().withFamily(it) } ?: defaultTextStyles()
            }
            ConsoleApp(controller, styles)
            LaunchedEffect(Unit) {
                withFrameNanos {}
                pageReady()
                controller.poll(::pageVisible)
            }
        }
    }
}
