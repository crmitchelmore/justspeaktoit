package com.justspeaktoit.android.readaloud

/**
 * Splits [text] into pieces of at most [maxLength] characters for `TextToSpeech.speak`, which
 * rejects longer input. Breaks after a sentence end or space where it can, so words stay whole.
 * A hard cut never separates a surrogate pair, which would send broken UTF-16 to the provider.
 */
internal fun speechChunks(text: String, maxLength: Int): List<String> {
    require(maxLength > 0)
    val chunks = mutableListOf<String>()
    var rest = text.trim()
    while (rest.length > maxLength) {
        val window = rest.substring(0, maxLength + 1)
        val sentence = window.lastIndexOfAny(charArrayOf('.', '!', '?', '\n')).takeIf { it > 0 && it < maxLength }
        val cut = sentence?.plus(1) ?: window.lastIndexOf(' ').takeIf { it > 0 } ?: codePointCut(rest, maxLength)
        chunks += rest.substring(0, cut).trim()
        rest = rest.substring(cut).trim()
    }
    if (rest.isNotEmpty()) chunks += rest
    return chunks.filter { it.isNotEmpty() }
}

/** [limit], or one less when that would split a surrogate pair; a lone pair at a limit of 1 stays whole. */
private fun codePointCut(text: String, limit: Int): Int = when {
    !Character.isSurrogatePair(text[limit - 1], text[limit]) -> limit
    limit > 1 -> limit - 1
    else -> 2
}
