package com.softdigi.softlocalpai

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingImport: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Android 11+ creates Android/data/<package> only through this API, so the
        // folder is owned by the app and the app can read model files placed in it.
        MethodChannel(messenger, "softlocalpai/paths").setMethodCallHandler { call, result ->
            when (call.method) {
                "externalFilesDir" -> {
                    val dir = getExternalFilesDir(null)
                    if (dir == null) {
                        result.error("unavailable", "external files directory is not available", null)
                    } else {
                        dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                }
                // Private app storage. Models live under <filesDir>/models.
                "filesDir" -> result.success(filesDir.absolutePath)
                // Free space on the filesystem containing the given path, for the
                // Download Center's storage check before a model download starts.
                "freeBytes" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("args", "path is required", null)
                    } else {
                        result.success(android.os.StatFs(path).availableBytes)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "softlocalpai/import").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickGguf" -> startGgufPicker(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "softlocalpai/thermal").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(thermalStatus())
                else -> result.notImplemented()
            }
        }
    }

    /// Thermal status as PowerManager.THERMAL_STATUS_* (0 = none ... 6 = shutdown).
    /// Returns 0 before Android 10, where the API does not exist.
    private fun thermalStatus(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val pm = getSystemService(PowerManager::class.java) ?: return 0
        return pm.currentThermalStatus
    }

    private fun startGgufPicker(result: MethodChannel.Result) {
        if (pendingImport != null) {
            result.error("busy", "an import is already running", null)
            return
        }
        pendingImport = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // GGUF has no registered MIME type, so offer everything and check the header after copying.
            type = "*/*"
        }
        startActivityForResult(intent, REQUEST_PICK_GGUF)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_GGUF) return
        val result = pendingImport ?: return
        pendingImport = null

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null) // cancelled
            return
        }
        val displayName = queryDisplayName(uri) ?: "model.gguf"

        Thread {
            try {
                val modelsDir = File(filesDir, "models").apply { mkdirs() }
                val partFile = File(modelsDir, "import-${UUID.randomUUID()}.part")
                val input = contentResolver.openInputStream(uri)
                    ?: throw java.io.IOException("could not open the selected file")
                input.use { source ->
                    FileOutputStream(partFile).use { output -> source.copyTo(output, 1 shl 20) }
                }
                // Check the GGUF magic before keeping the file.
                val magic = ByteArray(4)
                val read = partFile.inputStream().use { it.read(magic) }
                if (read != 4 || !magic.contentEquals("GGUF".toByteArray())) {
                    partFile.delete()
                    postError(result, "bad_header", "the selected file is not a GGUF model")
                    return@Thread
                }
                val finalFile = File(modelsDir, safeFileName(displayName, modelsDir))
                if (!partFile.renameTo(finalFile)) {
                    partFile.delete()
                    postError(result, "io", "could not finish copying the model")
                    return@Thread
                }
                val reply = mapOf(
                    "fileName" to finalFile.name,
                    "displayName" to displayName,
                    "sizeBytes" to finalFile.length(),
                )
                mainHandler.post { result.success(reply) }
            } catch (e: Exception) {
                postError(result, "copy_failed", e.message ?: e.javaClass.simpleName)
            }
        }.start()
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
        return null
    }

    /// Keeps the name readable but safe as a file name, and never overwrites an existing model.
    private fun safeFileName(displayName: String, dir: File): String {
        val base = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "model" }
        val stem = base.removeSuffix(".gguf")
        var candidate = "$stem.gguf"
        var n = 1
        while (File(dir, candidate).exists()) {
            candidate = "$stem-$n.gguf"
            n++
        }
        return candidate
    }

    companion object {
        private const val REQUEST_PICK_GGUF = 4301
    }
}
