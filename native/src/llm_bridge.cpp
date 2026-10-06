// extern "C" bridge consumed by Dart FFI. The ABI is documented in
// native/include/llm_bridge.h.
#include "llm_bridge.h"
#include "gguf.h"
#include "llama.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <cstring>
#include <mutex>
#include <new>
#include <unistd.h>
#include <vector>

#if defined(__GNUC__)
#define LLM_EXPORT __attribute__((visibility("default")))
#else
#define LLM_EXPORT
#endif

namespace {

constexpr int32_t kDefaultCtx = 2048;
constexpr int32_t kMaxThreads = 4;
constexpr int32_t kMaxUBatch = 512;

thread_local std::string g_last_error;

int32_t fail(int32_t code, const char * msg) {
    g_last_error = msg;
    return code;
}

void ensure_backend_init() {
    static std::once_flag once;
    std::call_once(once, [] { llama_backend_init(); });
}

// Frees a GGUF context when it goes out of scope.
struct ModelInfoGuard {
    gguf_context * gguf;
    ~ModelInfoGuard() { gguf_free(gguf); }
};

// Reads an integer key. GGUF writers use u32, i32 or u64 for these fields.
bool read_gguf_int(const gguf_context * gguf, const std::string & key, int32_t * out) {
    const int64_t id = gguf_find_key(gguf, key.c_str());
    if (id < 0) return false;
    switch (gguf_get_kv_type(gguf, id)) {
        case GGUF_TYPE_UINT32: *out = static_cast<int32_t>(gguf_get_val_u32(gguf, id)); return true;
        case GGUF_TYPE_INT32:  *out = gguf_get_val_i32(gguf, id); return true;
        case GGUF_TYPE_UINT64: *out = static_cast<int32_t>(gguf_get_val_u64(gguf, id)); return true;
        default: return false;
    }
}

// Size of the file in bytes, which is the weight data plus a small header. Returns 0 if unknown.
uint64_t file_size_bytes(const char * path) {
    FILE * f = std::fopen(path, "rb");
    if (!f) return 0;
    uint64_t size = 0;
    if (std::fseek(f, 0, SEEK_END) == 0) {
        const long end = std::ftell(f);
        if (end > 0) size = static_cast<uint64_t>(end);
    }
    std::fclose(f);
    return size;
}

}  // namespace

struct llm_session {
    llama_model *   model   = nullptr;
    llama_context * ctx     = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_sampler * sampler = nullptr;

    int32_t n_ctx     = 0;
    int32_t n_past    = 0;   // tokens currently in the KV cache
    int32_t n_gen     = 0;   // tokens sampled in the current generation
    int32_t max_gen   = 0;
    bool    active    = false;
    bool    done      = false;

    std::atomic<bool> stop_requested{false};

    ~llm_session() {
        if (sampler) llama_sampler_free(sampler);
        if (ctx)     llama_free(ctx);
        if (model)   llama_model_free(model);
    }
};

extern "C" {

LLM_EXPORT const char * llm_probe(void) {
    ensure_backend_init();
    return llama_print_system_info();
}

LLM_EXPORT llm_session * llm_load(const char * model_path, int32_t n_ctx, int32_t n_threads) {
    if (!model_path) {
        g_last_error = "model_path is NULL";
        return nullptr;
    }
    ensure_backend_init();

    if (n_ctx <= 0)     n_ctx = kDefaultCtx;
    if (n_threads <= 0) n_threads = llm_suggest_threads();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;  // CPU only on this target

    llama_model * model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        g_last_error = std::string("failed to load model: ") + model_path;
        return nullptr;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(n_ctx);
    cparams.n_batch         = static_cast<uint32_t>(n_ctx);
    cparams.n_ubatch        = static_cast<uint32_t>(n_ctx < kMaxUBatch ? n_ctx : kMaxUBatch);
    cparams.n_threads       = n_threads;
    cparams.n_threads_batch = n_threads;

    llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        g_last_error = "failed to create llama context";
        return nullptr;
    }

    llm_session * s = new (std::nothrow) llm_session();
    if (!s) {
        llama_free(ctx);
        llama_model_free(model);
        g_last_error = "out of memory";
        return nullptr;
    }
    s->model = model;
    s->ctx   = ctx;
    s->vocab = llama_model_get_vocab(model);
    s->n_ctx = static_cast<int32_t>(llama_n_ctx(ctx));
    g_last_error.clear();
    return s;
}

LLM_EXPORT int32_t llm_begin(llm_session * s, const char * prompt, int32_t max_new_tokens,
                             float temperature, uint32_t seed) {
    if (!s || !prompt || max_new_tokens <= 0) {
        return fail(LLM_ERR_ARGS, "llm_begin: invalid arguments");
    }

    const int32_t prompt_len = static_cast<int32_t>(std::strlen(prompt));
    std::vector<llama_token> tokens(static_cast<size_t>(prompt_len) + 8);
    int32_t n_tokens = llama_tokenize(s->vocab, prompt, prompt_len, tokens.data(),
                                      static_cast<int32_t>(tokens.size()), true, true);
    if (n_tokens < 0) {
        tokens.resize(static_cast<size_t>(-n_tokens));
        n_tokens = llama_tokenize(s->vocab, prompt, prompt_len, tokens.data(),
                                  static_cast<int32_t>(tokens.size()), true, true);
    }
    if (n_tokens <= 0) {
        return fail(LLM_ERR_TOKENIZE, "prompt tokenization failed");
    }
    // Leave room for at least one generated token.
    if (n_tokens + 1 > s->n_ctx) {
        return fail(LLM_ERR_CONTEXT, "prompt does not fit in the context window");
    }

    // Reset state from any previous generation.
    s->stop_requested.store(false);
    s->active = false;
    s->done   = false;
    llama_memory_clear(llama_get_memory(s->ctx), true);

    if (s->sampler) {
        llama_sampler_free(s->sampler);
        s->sampler = nullptr;
    }
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;
    s->sampler = llama_sampler_chain_init(sparams);
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(s->sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(s->sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(s->sampler, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(s->sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(s->sampler, llama_sampler_init_dist(seed));
    }

    llama_batch batch = llama_batch_get_one(tokens.data(), n_tokens);
    if (llama_decode(s->ctx, batch) != 0) {
        return fail(LLM_ERR_DECODE, "prompt decode failed");
    }

    s->n_past  = n_tokens;
    s->n_gen   = 0;
    s->max_gen = max_new_tokens;
    s->active  = true;
    g_last_error.clear();
    return LLM_OK;
}

LLM_EXPORT int32_t llm_next(llm_session * s, char * out, int32_t out_len) {
    if (!s || !out || out_len <= 0) {
        return fail(LLM_ERR_ARGS, "llm_next: invalid arguments");
    }
    if (!s->active) {
        return fail(LLM_ERR_STATE, "llm_next called before llm_begin");
    }

    // Tokens with an empty piece (e.g. control tokens with special=false) are
    // consumed here, so a 0 return always means end of generation.
    for (;;) {
        if (s->done || s->stop_requested.load() || s->n_gen >= s->max_gen) {
            s->done = true;
            return LLM_OK;
        }
        if (s->n_past >= s->n_ctx) {
            return fail(LLM_ERR_CONTEXT_FULL, "context window is full");
        }

        const llama_token tok = llama_sampler_sample(s->sampler, s->ctx, -1);
        if (llama_vocab_is_eog(s->vocab, tok)) {
            s->done = true;
            return LLM_OK;
        }

        char piece[256];
        const int32_t n = llama_token_to_piece(s->vocab, tok, piece, sizeof(piece), 0, false);
        if (n < 0 || n > out_len) {
            // Nothing was consumed yet, so the next call samples again from the same logits.
            return fail(LLM_ERR_BUFFER, "output buffer too small for token piece");
        }

        // llama_sampler_sample already accepted tok. Feed it back for fresh logits.
        llama_token next = tok;
        llama_batch batch = llama_batch_get_one(&next, 1);
        if (llama_decode(s->ctx, batch) != 0) {
            s->done = true;
            return fail(LLM_ERR_DECODE, "token decode failed");
        }
        s->n_past += 1;
        s->n_gen  += 1;

        if (n > 0) {
            std::memcpy(out, piece, static_cast<size_t>(n));
            g_last_error.clear();
            return n;
        }
    }
}

LLM_EXPORT void llm_stop(llm_session * s) {
    if (s) s->stop_requested.store(true);
}

LLM_EXPORT void llm_unload(llm_session * s) {
    delete s;
}

LLM_EXPORT int32_t llm_set_threads(llm_session * s, int32_t n_threads) {
    if (!s || n_threads <= 0) {
        return fail(LLM_ERR_ARGS, "llm_set_threads: invalid arguments");
    }
    llama_set_n_threads(s->ctx, n_threads, n_threads);
    g_last_error.clear();
    return LLM_OK;
}
LLM_EXPORT int32_t llm_suggest_threads(void) {
    const long nproc = sysconf(_SC_NPROCESSORS_CONF);
    const int32_t cores = nproc > 0 ? static_cast<int32_t>(nproc) : kMaxThreads;

    std::vector<long long> max_khz;
    for (int32_t i = 0; i < cores; ++i) {
        char path[128];
        std::snprintf(path, sizeof(path),
                      "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE * f = std::fopen(path, "r");
        if (!f) continue;
        long long khz = 0;
        if (std::fscanf(f, "%lld", &khz) == 1 && khz > 0) max_khz.push_back(khz);
        std::fclose(f);
    }
    if (max_khz.empty()) {
        return cores < kMaxThreads ? cores : kMaxThreads;
    }

    long long top = 0;
    for (long long khz : max_khz) top = khz > top ? khz : top;

    int32_t perf = 0;
    for (long long khz : max_khz) {
        if (khz * 10 >= top * 8) ++perf;
    }
    if (perf < 1) perf = 1;
    return perf < kMaxThreads ? perf : kMaxThreads;
}

LLM_EXPORT int32_t llm_read_model_info(const char * model_path, llm_model_info * out) {
    if (!model_path || !out) {
        return fail(LLM_ERR_ARGS, "llm_read_model_info: invalid arguments");
    }

    // Reads the GGUF header and key-value table only. No weights are loaded and
    // no tensor buffers are allocated.
    gguf_init_params gparams{};
    gparams.no_alloc = true;
    gparams.ctx = nullptr;
    gguf_context * gguf = gguf_init_from_file(model_path, gparams);
    if (!gguf) {
        return fail(LLM_ERR_LOAD, "not a readable GGUF file");
    }
    const ModelInfoGuard guard{gguf};

    const int64_t arch_id = gguf_find_key(gguf, "general.architecture");
    if (arch_id < 0 || gguf_get_kv_type(gguf, arch_id) != GGUF_TYPE_STRING) {
        return fail(LLM_ERR_LOAD, "GGUF metadata lacks general.architecture");
    }
    const std::string arch = gguf_get_val_str(gguf, arch_id);
    std::memset(out, 0, sizeof(*out));
    std::snprintf(out->arch, sizeof(out->arch), "%s", arch.c_str());

    int32_t n_layer = 0, n_head = 0, n_head_kv = 0, n_embd = 0, key_length = 0, n_ctx = 0;
    if (!read_gguf_int(gguf, arch + ".block_count", &n_layer) ||
        !read_gguf_int(gguf, arch + ".attention.head_count", &n_head) ||
        !read_gguf_int(gguf, arch + ".embedding_length", &n_embd) ||
        !read_gguf_int(gguf, arch + ".context_length", &n_ctx)) {
        return fail(LLM_ERR_LOAD, "GGUF metadata lacks layer, head, embedding or context sizes");
    }
    // Models without grouped-query attention store no separate KV head count.
    if (!read_gguf_int(gguf, arch + ".attention.head_count_kv", &n_head_kv)) {
        n_head_kv = n_head;
    }
    // Some architectures store the per-head key size explicitly; otherwise it is n_embd / n_head.
    if (!read_gguf_int(gguf, arch + ".attention.key_length", &key_length) || key_length <= 0) {
        key_length = n_head > 0 ? n_embd / n_head : 0;
    }

    int32_t n_vocab = 0;
    const int64_t tokens_id = gguf_find_key(gguf, "tokenizer.ggml.tokens");
    if (tokens_id >= 0 && gguf_get_kv_type(gguf, tokens_id) == GGUF_TYPE_ARRAY) {
        n_vocab = static_cast<int32_t>(gguf_get_arr_n(gguf, tokens_id));
    } else {
        read_gguf_int(gguf, arch + ".vocab_size", &n_vocab);
    }

    out->n_layer     = n_layer;
    out->n_head      = n_head;
    out->n_head_kv   = n_head_kv;
    out->n_embd      = n_embd;
    out->head_dim    = key_length;
    out->n_ctx_train = n_ctx;
    out->n_vocab     = n_vocab;
    out->size_bytes  = file_size_bytes(model_path);

    if (out->n_layer <= 0 || out->n_head <= 0 || out->n_head_kv <= 0 ||
        out->head_dim <= 0 || out->n_ctx_train <= 0) {
        return fail(LLM_ERR_LOAD, "GGUF metadata has non-positive model sizes");
    }
    g_last_error.clear();
    return LLM_OK;
}

LLM_EXPORT int32_t llm_count_tokens(llm_session * s, const char * text) {
    if (!s || !text) {
        return fail(LLM_ERR_ARGS, "llm_count_tokens: invalid arguments");
    }
    const int32_t len = static_cast<int32_t>(std::strlen(text));
    std::vector<llama_token> tokens(static_cast<size_t>(len) + 8);
    int32_t n = llama_tokenize(s->vocab, text, len, tokens.data(),
                               static_cast<int32_t>(tokens.size()), false, true);
    if (n < 0) {
        // Negative means the buffer was too small; -n is the required size.
        tokens.resize(static_cast<size_t>(-n));
        n = llama_tokenize(s->vocab, text, len, tokens.data(),
                           static_cast<int32_t>(tokens.size()), false, true);
    }
    if (n < 0) return fail(LLM_ERR_TOKENIZE, "token count failed");
    return n;
}

LLM_EXPORT int32_t llm_generated_count(llm_session * s) {
    return s ? s->n_gen : -1;
}

LLM_EXPORT const char * llm_last_error(void) {
    return g_last_error.c_str();
}

}  // extern "C"
