package com.justspeaktoit.android.dictation

import android.app.Application
import android.content.ContentResolver
import android.net.Uri
import java.io.InputStream

/** Reads audio another app shared; [ContentSharedAudioSource] in production. */
interface SharedAudioSource {
    /**
     * Only content shared through another app's provider is accepted. A file:// URI or one of this
     * app's own providers would be read with this app's privileges, which could upload its private data.
     */
    fun accepts(uri: Uri): Boolean

    /** The provider's MIME type, which is often more precise than the sender's declared one. */
    fun type(uri: Uri): String?

    /** Blocking; null when the provider cannot open the stream. */
    fun open(uri: Uri): InputStream?
}

class ContentSharedAudioSource(private val application: Application) : SharedAudioSource {
    private val resolver: ContentResolver get() = application.contentResolver

    override fun accepts(uri: Uri): Boolean = uri.scheme == ContentResolver.SCHEME_CONTENT && !isOwnProvider(uri)

    override fun type(uri: Uri): String? = resolver.getType(uri)

    override fun open(uri: Uri): InputStream? = resolver.openInputStream(uri)

    private fun isOwnProvider(uri: Uri): Boolean {
        val authority = uri.authority ?: return true
        @Suppress("DEPRECATION")
        val provider = application.packageManager.resolveContentProvider(authority, 0)
        return provider?.packageName == application.packageName
    }
}
