package com.gordonxc.geminisubtitles

import android.util.Base64

/** Android implementation of base64Encode using android.util.Base64. */
actual fun base64Encode(data: ByteArray): String =
    Base64.encodeToString(data, Base64.NO_WRAP)
