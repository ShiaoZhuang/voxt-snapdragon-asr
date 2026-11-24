#pragma once

#include "ggml-alloc.h"
#include "ggml-backend.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

// Run one ffn_down projection on the selected device, with no scheduler fallback.
inline int voxt_verify_ffn_down(const std::filesystem::path & directory, const std::string & device_name,
                               const std::string & variant) {
    constexpr int columns = 6144;
    constexpr int outputs = 2048;
    constexpr int tokens = 8;
    const bool dense = variant == "f32-batch";
    const int rows = variant == "q8-single" ? 1 : variant == "q8-batch4" ? 4 : tokens;
    if (!dense && variant != "q8-batch8" && variant != "q8-batch4" && variant != "q8-single") {
        throw std::invalid_argument("unknown FFN down probe variant: " + variant);
    }

    ggml_backend_load_all();
    auto * device = ggml_backend_dev_by_name(device_name.c_str());
    if (!device) {
        throw std::runtime_error("probe device was not found: " + device_name);
    }
    std::unique_ptr<ggml_backend, decltype(&ggml_backend_free)> backend(ggml_backend_dev_init(device, nullptr),
                                                                      ggml_backend_free);
    const ggml_init_params params{4 * ggml_tensor_overhead() + ggml_graph_overhead(), nullptr, true};
    std::unique_ptr<ggml_context, decltype(&ggml_free)> context(ggml_init(params), ggml_free);
    if (!backend || !context) {
        throw std::runtime_error("could not initialize the projection probe");
    }

    auto * weight = ggml_new_tensor_2d(context.get(), dense ? GGML_TYPE_F32 : GGML_TYPE_Q8_0, columns, outputs);
    auto * input = ggml_new_tensor_2d(context.get(), GGML_TYPE_F32, columns, rows);
    auto * output = ggml_mul_mat(context.get(), weight, input);
    ggml_set_name(weight, "blk.27.ffn_down.weight");
    if (!ggml_backend_supports_op(backend.get(), output)) {
        throw std::runtime_error("projection shape or type is unsupported by " + device_name);
    }
    auto * graph = ggml_new_graph(context.get());
    ggml_build_forward_expand(graph, output);
    std::unique_ptr<ggml_backend_buffer, decltype(&ggml_backend_buffer_free)> buffer(
        ggml_backend_alloc_ctx_tensors(context.get(), backend.get()), ggml_backend_buffer_free);
    if (!buffer) {
        throw std::runtime_error("could not allocate probe tensors on " + device_name);
    }

    const auto read = [&](const char * name, void * destination, size_t size) {
        const auto path = directory / name;
        if (std::filesystem::file_size(path) != size) {
            throw std::runtime_error(std::string("invalid projection input size: ") + name);
        }
        std::ifstream stream(path, std::ios::binary);
        stream.exceptions(std::ios::failbit | std::ios::badbit);
        stream.read(reinterpret_cast<char *>(destination), size);
    };
    std::vector<uint8_t> weight_bytes(ggml_nbytes(weight));
    std::vector<float> inputs(tokens * columns), results(tokens * outputs);
    read(dense ? "weight.f32" : "weight.q8", weight_bytes.data(), weight_bytes.size());
    read("swiglu.f32", inputs.data(), inputs.size() * sizeof(float));
    ggml_backend_tensor_set(weight, weight_bytes.data(), 0, weight_bytes.size());
    for (int token = 0; token < tokens; token += rows) {
        ggml_backend_tensor_set(input, inputs.data() + token * columns, 0, ggml_nbytes(input));
        if (ggml_backend_graph_compute(backend.get(), graph) != GGML_STATUS_SUCCESS) {
            throw std::runtime_error("projection failed on " + device_name);
        }
        ggml_backend_tensor_get(output, results.data() + token * outputs, 0, ggml_nbytes(output));
    }
    std::ofstream result(directory / (variant + ".f32"), std::ios::binary);
    result.exceptions(std::ios::failbit | std::ios::badbit);
    result.write(reinterpret_cast<const char *>(results.data()), results.size() * sizeof(float));
    result.close();
    return 0;
}
