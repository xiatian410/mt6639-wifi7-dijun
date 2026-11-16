package console

/**
 * The only command lines the console ever runs as root. Each is a constant,
 * or a constant plus a value checked against a fixed list; nothing typed by
 * the user is placed in a command line except hex digits.
 */
object Commands {
    const val MODULE = "/data/adb/modules/mt6639-hotspot"
    private const val CONTROL = "sh $MODULE/bin/radio-control.sh $MODULE"
    private const val KEY = "sh $MODULE/bin/radio-key.sh $MODULE"

    const val STATUS = "$CONTROL status"
    const val STATUS_FULL = "$CONTROL status full"
    const val STOP = "$CONTROL stop"
    const val SIX_ON = "$CONTROL six-on"
    const val SIX_OFF = "$CONTROL six-off"
    const val SIX_REFRESH = "$CONTROL six-refresh"
    const val LOGS = "$CONTROL logs"

    /** The script reads the hex digits from standard input, never from its arguments. */
    const val SET_KEY_SUFFIX = " | $KEY set"

    fun start(width: Int): String {
        require(width in WIDTHS)
        return "$CONTROL start $width"
    }

    fun setWidth(width: Int): String {
        require(width in WIDTHS)
        return "$CONTROL set-width $width"
    }

    const val SET_NAME_SUFFIX = " | sh $MODULE/bin/radio-name.sh $MODULE set"

    fun setName(name: String): String = "echo ${ssidHex(name)}$SET_NAME_SUFFIX"

    fun setKey(passphrase: String): String = "echo ${passphraseHex(passphrase)}$SET_KEY_SUFFIX"
}
