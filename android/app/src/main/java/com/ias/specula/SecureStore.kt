package com.ias.specula

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

@Suppress("DEPRECATION")
class SecureStore(context: Context) : Secrets {
    private val preferences =
        EncryptedSharedPreferences.create(
            context,
            "credentials",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    override fun get(key: String): String? = preferences.getString(key, null)

    override fun put(key: String, value: String?) {
        val edit = preferences.edit()
        if (value == null) edit.remove(key) else edit.putString(key, value)
        if (!edit.commit()) throw java.io.IOException("연결 정보를 안전하게 저장하지 못했습니다.")
    }
}
