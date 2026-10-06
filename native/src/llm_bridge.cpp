// extern "C" bridge consumed by Dart FFI. The ABI is documented in
// native/include/llm_bridge.h.
#include "llm_bridge.h"
#include "llama.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
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

LLM_EXPORT int32_t llm_generated_count(llm_session * s) {
    return s ? s->n_gen : -1;
}

LLM_EXPORT const char * llm_last_error(void) {
    return g_last_error.c_str();
}

}  // extern "C"
