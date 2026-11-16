package console

import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import top.yukonga.miuix.kmp.theme.TextStyles
import kotlin.coroutines.resume
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

// The canvas renderer has no access to system fonts and ships no CJK glyphs,
// and a root console must not depend on a font server. The module carries its
// own subset (see tools/build_webui.sh); these are fetched from the module.
private val FONT_FILES = listOf(
    "fonts/ui-400.otf" to FontWeight.Normal,
    "fonts/ui-500.otf" to FontWeight.Medium,
    "fonts/ui-700.otf" to FontWeight.Bold,
)

@OptIn(ExperimentalEncodingApi::class)
private suspend fun fetchBytes(url: String): ByteArray? = suspendCancellableCoroutine { continuation ->
    jsFetchBase64(
        url,
        { text -> if (continuation.isActive) continuation.resume(runCatching { Base64.decode(text) }.getOrNull()) },
        { if (continuation.isActive) continuation.resume(null) },
    )
}

/** Null when no font file could be loaded; the page then uses the renderer's default. */
suspend fun loadConsoleFonts(): FontFamily? {
    val fonts: List<Font> = coroutineScope {
        FONT_FILES.map { (url, weight) ->
            async {
                fetchBytes(url)?.let { data ->
                    runCatching { Font(identity = url, getData = { data }, weight = weight) }.getOrNull()
                }
            }
        }.awaitAll().filterNotNull()
    }
    return if (fonts.isEmpty()) null else FontFamily(fonts)
}

fun TextStyles.withFamily(family: FontFamily): TextStyles = copy(
    main = main.copy(fontFamily = family),
    paragraph = paragraph.copy(fontFamily = family),
    body1 = body1.copy(fontFamily = family),
    body2 = body2.copy(fontFamily = family),
    button = button.copy(fontFamily = family),
    footnote1 = footnote1.copy(fontFamily = family),
    footnote2 = footnote2.copy(fontFamily = family),
    headline1 = headline1.copy(fontFamily = family),
    headline2 = headline2.copy(fontFamily = family),
    subtitle = subtitle.copy(fontFamily = family),
    title1 = title1.copy(fontFamily = family),
    title2 = title2.copy(fontFamily = family),
    title3 = title3.copy(fontFamily = family),
    title4 = title4.copy(fontFamily = family),
)
