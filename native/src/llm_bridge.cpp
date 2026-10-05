// Thin extern "C" bridge consumed by Dart FFI. Grows to the full API
// (llm_probe, llm_load, llm_begin, llm_next, llm_stop, llm_unload, ...).
#include "llama.h"

#include <cstdint>

#if defined(__GNUC__)
#define LLM_EXPORT __attribute__((visibility("default")))
#else
#define LLM_EXPORT
#endif

extern "C" {

// Initializes the llama backend once and returns a static system-info string.
LLM_EXPORT const char * llm_probe(void) {
    llama_backend_init();
    return llama_print_system_info();
}

}  // extern "C"
