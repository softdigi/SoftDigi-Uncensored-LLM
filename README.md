# SoftDigi AI

SoftDigi AI, by SoftDigi Technology. Your AI. Your Device. Your Privacy.

Flutter Android app with on-device LLM inference (llama.cpp via Dart FFI).
Target device: arm64-v8a, Snapdragon 8 Gen 2 (SM8550), Android 8.0+ (minSdk 26).

## Clone and build

```sh
git clone <repo-url> softlocalpai
cd softlocalpai
git submodule update --init --recursive   # native/third_party/llama.cpp
flutter pub get
```

Create `android/local.properties` (gitignored) with `flutter.sdk` and `sdk.dir`.
Flutter writes these for you on the first `flutter run`.

## Release signing

The build reads signing from `android/key.properties`, which is gitignored.
There is no debug-key fallback. A missing or incomplete file fails the Gradle
configuration step, and this applies to debug, profile and release builds.

1. Copy `android/key.properties.example` to `android/key.properties`.
2. Set `storeFile` (path to the keystore, outside the repo), `storePassword`, `keyAlias` and `keyPassword`.

Never commit keystores, `key.properties`, GGUF models or `local.properties`.

## Model

The GGUF model is not in the repo (about 2 GB). Current test model:
`Llama-3.2-3B-Instruct-Q4_K_M.gguf`. Push it to the app's external files directory:

```sh
adb push Llama-3.2-3B-Instruct-Q4_K_M.gguf /sdcard/Android/data/com.softdigi.softlocalpai/files/model.gguf
```

## Native bridge

- `native/include/llm_bridge.h`: C ABI (`llm_load`, `llm_begin`, `llm_next`, `llm_stop`, `llm_unload`, `llm_set_threads`, `llm_suggest_threads`).
- `native/src/llm_bridge.cpp`: implementation, linked statically against llama.cpp.
- `native/tests/llm_bridge_smoke.cpp`: device CLI, built only with `-DLLM_BRIDGE_SMOKE=ON`.
- `lib/llm/`: Dart FFI bindings, `LlmEngine`, and the Llama 3 prompt builder.

Device smoke test without the Flutter build (needs the Android NDK 28.2.13676358):

```sh
cmake -S native -B build/native-smoke -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DLLM_BRIDGE_SMOKE=ON
cmake --build build/native-smoke --target llm_bridge_smoke
adb push build/native-smoke/llm_bridge_smoke /data/local/tmp/llm/
adb shell "cd /data/local/tmp/llm && ./llm_bridge_smoke model.gguf '<prompt>' 64 4 0.7"
```

## Run

```sh
flutter test test/llm
flutter run -t lib/llm/llm_smoke_main.dart   # on-device inference check (not the app UI)
```
