package com.proxynodeassistant.android

import android.app.Application
import com.proxynodeassistant.android.data.AppContainer

class ProxyNodeApplication : Application() {
    val container: AppContainer by lazy { AppContainer(this) }
}
