#pragma once

#include "verify_socket.h"
#include "ggml-backend.h"
#include "llama-batch.h"
#include "llama-graph.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <set>
#include <stdexcept>
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
void append(std::vector<char> & packet, const T * data, size_t count) {
    const auto * bytes = reinterpret_cast<const char *>(data);
    packet.insert(packet.end(), bytes, bytes + count * sizeof(T));
}

inline void verify(llm_graph_result * res, const llama_ubatch & batch) {
    const auto began = std::chrono::steady_clock::now();
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

    const int32_t count = prefix.size();
    std::vector<char> packet;
    packet.reserve((1 + rows * 5) * sizeof(int32_t) + caches.size() * count * kv_width * sizeof(ggml_fp16_t));
    append(packet, &count, 1);
    append(packet, batch.token, rows);
    append(packet, batch.pos, 4 * rows);
    const size_t cached_rows = prefix.empty() ? 0 : *std::max_element(prefix.begin(), prefix.end()) + 1;
    std::vector<ggml_fp16_t> cache(cached_rows * kv_width);
    for (auto * tensor : caches) {
        if (cache.empty()) {
            continue;
        }
        ggml_backend_tensor_get(tensor, cache.data(), 0, cache.size() * sizeof(cache[0]));
        for (auto slot : prefix) {
            append(packet, cache.data() + slot * kv_width, kv_width);
        }
    }
    const auto sent = static_cast<long long>(packet.size());
    const char * token = std::getenv("VOXT_QNN_VERIFY_TOKEN");
    require(token && std::string(token).size() == 32, "missing QNN worker token");
    verify_socket channel;
    channel.connect_worker();
    const auto published = std::chrono::steady_clock::now();
    const uint32_t length = htonl(static_cast<uint32_t>(packet.size()));
    channel.send_all(token, 32);
    channel.send_all(&length, sizeof(length));
    channel.send_all(packet.data(), packet.size());
    uint32_t reply = 0;
    channel.receive(&reply, sizeof(reply));
    const auto received = std::chrono::steady_clock::now();
    std::vector<ggml_fp16_t> kv(caches.size() * rows * kv_width);
    std::vector<float> aux(outputs.size() * rows * width), scores(rows * vocab);
    const size_t bytes = kv.size() * sizeof(kv[0]) + (aux.size() + scores.size()) * sizeof(float);
    require(ntohl(reply) == bytes, "invalid QNN loopback response byte count");
    channel.receive(kv.data(), kv.size() * sizeof(kv[0]));
    channel.receive(aux.data(), aux.size() * sizeof(float));
    channel.receive(scores.data(), scores.size() * sizeof(float));

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
    if (std::getenv("VOXT_TRACE_INTERDEVICE_COPY")) {
        using micros = std::chrono::microseconds;
        std::fprintf(stderr, "voxt: verify IPC bytes %lld %zu us prepare %lld wait %lld apply %lld\n", sent, bytes,
            (long long) std::chrono::duration_cast<micros>(published - began).count(),
            (long long) std::chrono::duration_cast<micros>(received - published).count(),
            (long long) std::chrono::duration_cast<micros>(std::chrono::steady_clock::now() - received).count());
    }
}
}
