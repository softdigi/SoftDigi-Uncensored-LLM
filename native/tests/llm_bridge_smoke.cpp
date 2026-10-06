// Device smoke test for the bridge C API. Built only with -DLLM_BRIDGE_SMOKE=ON.
// Usage: llm_bridge_smoke <model.gguf> [prompt] [max_tokens] [threads] [temperature] [stop_after_pieces]
#include "llm_bridge.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// Prints the process resident set size from /proc/self/status.
static void print_rss(const char * tag) {
    FILE * f = std::fopen("/proc/self/status", "r");
    if (!f) return;
    char line[256];
    while (std::fgets(line, sizeof(line), f)) {
        if (std::strncmp(line, "VmRSS:", 6) == 0) {
            std::printf("rss %s: %s", tag, line + 6);
            break;
        }
    }
    std::fclose(f);
}

int main(int argc, char ** argv) {
    // --info <model.gguf>: print the architecture facts read from the metadata.
    if (argc == 3 && std::strcmp(argv[1], "--info") == 0) {
        llm_model_info info{};
        if (llm_read_model_info(argv[2], &info) != LLM_OK) {
            std::fprintf(stderr, "llm_read_model_info failed: %s\n", llm_last_error());
            return 1;
        }
        std::printf("arch=%s layers=%d heads=%d kv_heads=%d embd=%d head_dim=%d ctx_train=%d vocab=%d size=%llu\n",
                    info.arch, info.n_layer, info.n_head, info.n_head_kv, info.n_embd,
                    info.head_dim, info.n_ctx_train, info.n_vocab,
                    static_cast<unsigned long long>(info.size_bytes));
        return 0;
    }
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.gguf> [prompt] [max_tokens] [threads] [temperature]\n", argv[0]);
        return 2;
    }
    const char * model_path = argv[1];
    const char * prompt     = argc > 2 ? argv[2] : "Hello";
    const int32_t max_tokens = argc > 3 ? std::atoi(argv[3]) : 64;
    const int32_t threads    = argc > 4 ? std::atoi(argv[4]) : 0;
    const float temperature  = argc > 5 ? static_cast<float>(std::atof(argv[5])) : 0.0f;
    const int32_t stop_after = argc > 6 ? std::atoi(argv[6]) : 0;  // 0 = never call llm_stop

    std::printf("system: %s\n", llm_probe());
    std::printf("suggested threads: %d\n", llm_suggest_threads());

    auto t0 = std::chrono::steady_clock::now();
    llm_session * s = llm_load(model_path, 2048, threads);
    if (!s) {
        std::fprintf(stderr, "llm_load failed: %s\n", llm_last_error());
        return 1;
    }
    auto t1 = std::chrono::steady_clock::now();
    std::printf("load: %lld ms\n", static_cast<long long>(
        std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count()));
    print_rss("after load");

    int32_t rc = llm_begin(s, prompt, max_tokens, temperature, 1234u);
    if (rc != LLM_OK) {
        std::fprintf(stderr, "llm_begin failed (%d): %s\n", rc, llm_last_error());
        llm_unload(s);
        return 1;
    }
    auto t2 = std::chrono::steady_clock::now();
    std::printf("prefill: %lld ms\n", static_cast<long long>(
        std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count()));

    std::string out;
    int32_t n_pieces = 0;
    char buf[512];
    for (;;) {
        rc = llm_next(s, buf, sizeof(buf));
        if (rc == LLM_OK) break;
        if (rc < 0) {
            std::fprintf(stderr, "\nllm_next failed (%d): %s\n", rc, llm_last_error());
            llm_unload(s);
            return 1;
        }
        out.append(buf, static_cast<size_t>(rc));
        ++n_pieces;
        if (stop_after > 0 && n_pieces == stop_after) {
            llm_stop(s);
            std::printf("[llm_stop called after %d pieces]\n", n_pieces);
        }
    }
    auto t3 = std::chrono::steady_clock::now();
    const double gen_s = std::chrono::duration<double>(t3 - t2).count();

    std::printf("--- output ---\n%s\n--- end ---\n", out.c_str());
    std::printf("stopped_by_request: %s\n", (stop_after > 0 && n_pieces >= stop_after) ? "yes" : "no");
    std::printf("pieces: %d, decode: %.2f s, %.2f pieces/s\n", n_pieces, gen_s,
                gen_s > 0 ? n_pieces / gen_s : 0.0);
    print_rss("after generate");

    llm_unload(s);
    print_rss("after unload");
    return n_pieces > 0 ? 0 : 1;
}
