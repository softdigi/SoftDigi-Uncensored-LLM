package com.softdigi.softlocalpai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 11+ creates Android/data/<package> only through this API, so the
        // folder is owned by the app and the app can read model files placed in it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "softlocalpai/paths")
            .setMethodCallHandler { call, result ->
                if (call.method == "externalFilesDir") {
                    val dir = getExternalFilesDir(null)
                    if (dir == null) {
                        result.error("unavailable", "external files directory is not available", null)
                    } else {
                        dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
