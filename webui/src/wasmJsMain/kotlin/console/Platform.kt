@file:OptIn(ExperimentalWasmJsInterop::class)

package console

import kotlin.js.ExperimentalWasmJsInterop

// Thin bindings to resources/bridge.js. Nothing else in the page talks to JavaScript.

@JsFun("() => window.mt6639.available()")
internal external fun ksuAvailable(): Boolean

@JsFun("(command, onLine, onDone) => window.mt6639.run(command, onLine, onDone)")
internal external fun jsRun(command: String, onLine: (Boolean, String) -> Unit, onDone: (Int) -> Unit)

@JsFun("(url, onOk, onErr) => window.mt6639.fetchBase64(url, onOk, onErr)")
internal external fun jsFetchBase64(url: String, onOk: (String) -> Unit, onErr: (String) -> Unit)

@JsFun("(title, hint, initial, secret, validate, save) => window.mt6639.promptInput(title, hint, initial, secret, validate, save)")
internal external fun jsPromptInput(title: String, hint: String, initial: String, secret: Boolean,
    validate: (String) -> String, save: (String) -> Boolean)

@JsFun("(page, card, text, weak, line, primary, onPrimary, field, error) => window.mt6639.setTheme(page, card, text, weak, line, primary, onPrimary, field, error)")
internal external fun jsSetTheme(page: String, card: String, text: String, weak: String, line: String,
    primary: String, onPrimary: String, field: String, error: String)

@JsFun("() => window.mt6639.visible()")
internal external fun pageVisible(): Boolean

@JsFun("() => window.mt6639.ready()")
internal external fun pageReady()

@JsFun("(name) => new URLSearchParams(window.location.search).get(name) || ''")
internal external fun queryParam(name: String): String
