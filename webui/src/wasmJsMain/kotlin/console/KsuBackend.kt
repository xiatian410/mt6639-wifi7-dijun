package console

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** Runs commands in the KernelSU manager's root shell through resources/bridge.js. */
class KsuBackend : Backend {
    override val demo: Boolean = false

    override suspend fun run(command: String, onLine: (stderr: Boolean, text: String) -> Unit): Int =
        suspendCancellableCoroutine { continuation ->
            jsRun(
                command,
                { stderr, text -> if (continuation.isActive) onLine(stderr, text) },
                { code -> if (continuation.isActive) continuation.resume(code) },
            )
        }
}
