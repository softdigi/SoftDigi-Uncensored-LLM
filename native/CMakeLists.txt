cmake_minimum_required(VERSION 3.22)
project(llm_bridge C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)

# llama.cpp is linked statically; only the thin bridge becomes a shared library.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)

# Snapdragon 8 Gen 2 (Cortex-X3/A715/A510): dotprod + fp16, no host-native tuning.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)

add_subdirectory(third_party/llama.cpp)

add_library(llm_bridge SHARED src/llm_bridge.cpp)
target_include_directories(llm_bridge PRIVATE third_party/llama.cpp/include)
target_link_libraries(llm_bridge PRIVATE llama)
# Hide ggml/llama internals; only the extern "C" bridge symbols are exported.
# max-page-size=16384 gives 16 KB ELF alignment for Android 15+ devices.
target_link_options(llm_bridge PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,-z,max-page-size=16384)
