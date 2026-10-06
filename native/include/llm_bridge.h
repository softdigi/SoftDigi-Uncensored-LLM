// C ABI of the llama.cpp bridge consumed by Dart FFI (lib/llm/llm_bindings.dart).
//
// Lifecycle: llm_load -> llm_begin -> llm_next (repeat) -> llm_unload.
// One session holds one model and one context. A session is not thread-safe,
// except llm_stop, which may be called from another thread while llm_next runs.
#ifndef LLM_BRIDGE_H
#define LLM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return codes. llm_next returns a positive byte count for text, 0 for end of
// generation, and a negative LLM_ERR_* value on failure.
#define LLM_OK                 0
#define LLM_ERR_ARGS          -1
#define LLM_ERR_LOAD          -2
#define LLM_ERR_CONTEXT       -3
#define LLM_ERR_TOKENIZE      -4
#define LLM_ERR_DECODE        -5
#define LLM_ERR_BUFFER        -6
#define LLM_ERR_STATE         -7
#define LLM_ERR_CONTEXT_FULL  -8

typedef struct llm_session llm_session;

// Static backend/system info string. Safe to call at any time.
const char * llm_probe(void);

// Loads a GGUF model and creates a context. n_ctx <= 0 uses 2048.
// n_threads <= 0 uses llm_suggest_threads(). Returns NULL on failure;
// llm_last_error() describes why.
llm_session * llm_load(const char * model_path, int32_t n_ctx, int32_t n_threads);

// Tokenizes prompt (BOS added, special tokens parsed), resets the KV cache,
// evaluates the prompt and prepares sampling. temperature <= 0 selects greedy
// decoding. Returns LLM_OK or a negative error.
int32_t llm_begin(llm_session * s, const char * prompt, int32_t max_new_tokens,
                  float temperature, uint32_t seed);

// Samples the next token and writes its UTF-8 bytes (not NUL-terminated) into
// out. A token's bytes may be an incomplete UTF-8 sequence; the caller must
// accumulate bytes across calls. Returns bytes written (> 0), 0 at end of
// generation (EOG, max_new_tokens reached, or llm_stop), or a negative error.
int32_t llm_next(llm_session * s, char * out, int32_t out_len);

// Requests that the current generation stop. Takes effect on the next llm_next.
void llm_stop(llm_session * s);

// Frees the model, context and sampler. s must not be used afterwards.
void llm_unload(llm_session * s);

// Changes the generation and batch thread count. Returns LLM_OK or an error.
int32_t llm_set_threads(llm_session * s, int32_t n_threads);

// Suggests a thread count from the CPU's maximum frequencies: performance
// cores (within 80% of the fastest core) capped at 4. Falls back to 4.
int32_t llm_suggest_threads(void);

// Tokens sampled (including ones with empty text) since the last llm_begin.
// Lets the caller tell max-tokens apart from end-of-turn. Returns -1 for a NULL session.
int32_t llm_generated_count(llm_session * s);

// Message for the most recent failure on the calling thread. Never NULL.
const char * llm_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // LLM_BRIDGE_H
