#pragma once

#include "ggml-backend.h"
#include "llama-batch.h"
#include "llama-graph.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>
#include <thread>
#include <vector>

// The host preserves llama.cpp's physical KV slots and decision/rollback logic.
// The worker sees a compact prefix plus eight causal rows.
namespace voxt_live {
constexpr int rows = 8;
constexpr int layers = 28;
constexpr int width = 2048;
constexpr int vocab = 151936;
constexpr int kv_width = 1024;
constexpr int aux_layers[] = {2, 14, 25};

inline std::filesystem::path directory() {
#ifdef _WIN32
    const auto * path = _wgetenv(L"VOXT_QNN_VERIFY_DIR");
#else
    const auto * path = std::getenv("VOXT_QNN_VERIFY_DIR");
#endif
    return path ? path : std::filesystem::path{};
}

inline void require(bool condition, const char * message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

template<class T>
std::vector<T> read_tensor(const ggml_tensor * tensor, ggml_type type, size_t elements) {
    require(tensor && tensor->buffer && tensor->type == type && size_t(ggml_nelements(tensor)) == elements &&
            ggml_is_contiguous(tensor), "unexpected verifier graph input");
    std::vector<T> result(elements);
    ggml_backend_tensor_get(tensor, result.data(), 0, elements * sizeof(T));
    return result;
}

template<class T>
void write(std::ostream & file, const T * data, size_t count) {
    file.write(reinterpret_cast<const char *>(data), count * sizeof(T));
}

template<class T>
void read(std::istream & file, T * data, size_t count) {
    file.read(reinterpret_cast<char *>(data), count * sizeof(T));
}

inline void verify(llm_graph_result * res, const llama_ubatch & batch) {
    const auto root = directory();
    auto * graph = res->get_gf();
    auto * mask_tensor = ggml_graph_get_tensor(graph, "attn_inp_kq_mask");
    require(mask_tensor && mask_tensor->ne[1] == rows && mask_tensor->ne[2] == 1 &&
            mask_tensor->ne[3] == 1 && batch.n_pos == 4, "unexpected verification mask");
    const int cols = mask_tensor->ne[0];
    auto mask = read_tensor<ggml_fp16_t>(mask_tensor, GGML_TYPE_F16, cols * rows);
    const auto slots = read_tensor<int64_t>(ggml_graph_get_tensor(graph, "attn_inp_k_idxs"), GGML_TYPE_I64, rows);
    require(slots == read_tensor<int64_t>(ggml_graph_get_tensor(graph, "attn_inp_v_idxs"), GGML_TYPE_I64, rows),
            "verification requires matching non-transposed K/V slots");
    auto * row_tensor = ggml_graph_get_tensor(graph, "attn_inp_kv_rows");
    const auto mapping = row_tensor ? read_tensor<int32_t>(row_tensor, GGML_TYPE_I32, cols) : std::vector<int32_t>{};
    std::set<int64_t> seen;
    std::vector<int64_t> prefix;
    for (int i = 0; i < cols; ++i) {
        const int64_t physical = row_tensor ? mapping[i] : i;
        const auto current = std::find(slots.begin(), slots.end(), physical);
        const bool prior = current == slots.end() && ggml_fp16_to_fp32(mask[i]) == 0.0f;
        if (prior || current != slots.end()) {
            require(physical >= 0 && seen.insert(physical).second, "invalid or repeated KV slot");
        }
        if (prior) {
            prefix.push_back(physical);
        }
        for (int row = 0; row < rows; ++row) {
            const float expected = (prior || (current != slots.end() && current - slots.begin() <= row)) ? 0.0f : -INFINITY;
            require(ggml_fp16_to_fp32(mask[row * cols + i]) == expected, "unsupported verification attention mask");
        }
    }
    require(seen.size() == prefix.size() + rows, "missing staged slots in the attention mask");

    std::vector<ggml_tensor *> caches;
    for (int layer = 0; layer < layers; ++layer) {
        for (const char kind : {'k', 'v'}) {
            const auto name = std::string("cache_") + kind + "_l" + std::to_string(layer);
            auto * tensor = ggml_graph_get_tensor(graph, name.c_str());
            require(tensor && tensor->buffer && tensor->type == GGML_TYPE_F16 && tensor->ne[0] == kv_width &&
                    tensor->ne[2] == 1 && tensor->ne[3] == 1 && ggml_is_contiguous(tensor), "unexpected live KV storage");
            require(*seen.rbegin() < tensor->ne[1], "KV slot outside cache");
            caches.push_back(tensor);
        }
    }
    std::vector<ggml_tensor *> outputs;
    for (int layer : aux_layers) {
        auto * tensor = res->get_layer_inp(layer);
        require(tensor && tensor->type == GGML_TYPE_F32 && ggml_is_contiguous(tensor) &&
                ggml_nelements(tensor) == rows * width && (tensor->flags & GGML_TENSOR_FLAG_OUTPUT),
                "unexpected DFlash context buffer");
        outputs.push_back(tensor);
    }
    auto * logits = res->get_logits();
    require(logits && logits->type == GGML_TYPE_F32 && ggml_is_contiguous(logits) &&
            ggml_nelements(logits) == rows * vocab, "unexpected Target logits buffer");
    require(std::all_of(outputs.begin(), outputs.end(), [](const auto * tensor) { return tensor->buffer; }) &&
            logits->buffer, "missing verifier output allocation");

    const auto request = root / "request.bin";
    const auto response = root / "response.bin";
    const auto error = root / "error.json";
    require(!std::filesystem::exists(request) && !std::filesystem::exists(response) &&
            !std::filesystem::exists(error), "verifier worker unavailable or previous transaction incomplete");
    const auto staging = root / "request.tmp";
    std::ofstream out(staging, std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    const int32_t count = prefix.size();
    write(out, &count, 1);
    write(out, batch.token, rows);
    write(out, batch.pos, 4 * rows);
    const size_t cached_rows = prefix.empty() ? 0 : *std::max_element(prefix.begin(), prefix.end()) + 1;
    std::vector<ggml_fp16_t> cache(cached_rows * kv_width);
    for (auto * tensor : caches) {
        if (cache.empty()) {
            continue;
        }
        ggml_backend_tensor_get(tensor, cache.data(), 0, cache.size() * sizeof(cache[0]));
        for (auto slot : prefix) {
            write(out, cache.data() + slot * kv_width, kv_width);
        }
    }
    out.close();
    std::filesystem::rename(staging, request);

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!std::filesystem::exists(response)) {
        require(!std::filesystem::exists(error), "verifier worker reported an error");
        require(std::chrono::steady_clock::now() < deadline, "live verifier timed out");
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::vector<ggml_fp16_t> kv(caches.size() * rows * kv_width);
    std::vector<float> aux(outputs.size() * rows * width), scores(rows * vocab);
    std::ifstream in(response, std::ios::binary);
    in.exceptions(std::ios::failbit | std::ios::badbit);
    read(in, kv.data(), kv.size());
    read(in, aux.data(), aux.size());
    read(in, scores.data(), scores.size());
    require(in.peek() == EOF, "invalid verifier response size");
    in.close();
    std::filesystem::remove(response);

    // Publish all outputs before the regular decoder samples and trims the staged KV.
    for (size_t i = 0; i < caches.size(); ++i) {
        for (int row = 0; row < rows; ++row) {
            ggml_backend_tensor_set(caches[i], kv.data() + (i * rows + row) * kv_width,
                                    slots[row] * caches[i]->nb[1], kv_width * sizeof(kv[0]));
        }
    }
    for (size_t i = 0; i < outputs.size(); ++i) {
        ggml_backend_tensor_set(outputs[i], aux.data() + i * rows * width, 0, rows * width * sizeof(float));
    }
    ggml_backend_tensor_set(logits, scores.data(), 0, scores.size() * sizeof(float));
}
}
