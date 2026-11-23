#pragma once

#include "common.h"
#include "ggml-backend.h"
#include "json.h"
#include "log.h"
#include "verify_attention_capture.h"

#include <array>
#include <charconv>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string_view>
#include <vector>

// A diagnostic capture of the first full DFlash verification batch on a single ASR slot.
class voxt_verify_capture {
public:
    static constexpr int positions = 8;
    static constexpr int target_layers = 28;

    void configure(common_params & params) {
#ifdef _WIN32
        const auto * path = _wgetenv(L"VOXT_VERIFY_CAPTURE_DIR");
        const auto * all_layers = _wgetenv(L"VOXT_VERIFY_CAPTURE_ALL_LAYERS");
#else
        const auto * path = std::getenv("VOXT_VERIFY_CAPTURE_DIR");
        const auto * all_layers = std::getenv("VOXT_VERIFY_CAPTURE_ALL_LAYERS");
#endif
        if (path && *path && !params.cb_eval && !saved) {
            directory = path;
            layer_count = all_layers && all_layers[0] == '1' && !all_layers[1] ? target_layers : 1;
            params.cb_eval = eval;
            params.cb_eval_user_data = this;
        }
    }

    bool enabled() const { return !directory.empty() && !saved; }

    void begin() {
        input.clear();
        up.clear();
        output.clear();
        layers = {};
        logits.clear();
        active = true;
    }

    void finish(bool decoded, const std::array<int, positions> & tokens, const std::array<int, positions> & pos) {
        active = false;
        if (!decoded || input.empty() || up.empty() || output.empty()) {
            return;
        }
        saved = true;
        try {
            if (!std::filesystem::create_directory(directory)) {
                throw std::runtime_error("capture directory already exists");
            }
            write_tensor("ffn_norm.f32", input);
            write_tensor("ffn_up.f32", up);
            write_tensor("ffn_out.f32", output);
            for (int i = 0; i < layer_count; ++i) {
                const auto & layer = layers[i];
                const auto folder = i == 0 ? directory : directory / ("layer-" + std::to_string(i));
                if (layer.residual.empty() || layer.output.empty()) {
                    if (layer_count > 1) {
                        throw std::runtime_error("missing layer state at layer " + std::to_string(i));
                    }
                    break;
                }
                if (i > 0) {
                    std::filesystem::create_directory(folder);
                }
                write_tensor(folder / "attention_residual.f32", layer.residual);
                write_tensor(folder / "layer_out.f32", layer.output);
                if (!layer.attention.save(folder) && layer_count > 1) {
                    throw std::runtime_error("missing attention state at layer " + std::to_string(i));
                }
            }
            if (layer_count > 1) {
                if (logits.empty()) {
                    throw std::runtime_error("missing verification logits");
                }
                write_tensor("target_logits.f32", logits);
            }
            std::ofstream manifest(directory / "capture.json");
            manifest.exceptions(std::ios::failbit | std::ios::badbit);
            manifest << common_json({
                {"layer", 0}, {"dtype", "float32-le"},
                {"layer_count", layer_count},
                {"logit_columns", logits.size() / positions},
                {"tokens", std::vector<int>(tokens.begin(), tokens.end())},
                {"positions", std::vector<int>(pos.begin(), pos.end())},
                {"input_shape", common_json::array({positions, 2048})},
                {"output_shape", common_json::array({positions, 6144})},
                {"ffn_output_shape", common_json::array({positions, 2048})},
            }).dump(2) << '\n';
            manifest.close();
        } catch (const std::exception & error) {
            LOG_ERR("Voxt verification capture: %s\n", error.what());
        }
    }

private:
    static bool eval(ggml_tensor * tensor, bool ask, void * user_data) {
        auto & self = *static_cast<voxt_verify_capture *>(user_data);
        if (!self.active) {
            return !ask;
        }
        std::string_view name = ggml_get_name(tensor);
        if (self.layer_count > 1 && name == "result_output" && tensor->ne[0] == 151936) {
            return collect(tensor, self.logits, ask);
        }
        // The flash node is unnamed. Its query is the per-layer Qcur through a view and a permute.
        if (tensor->op == GGML_OP_FLASH_ATTN_EXT) {
            const auto * query = tensor->src[0];
            while (query && (query->op == GGML_OP_PERMUTE || query->op == GGML_OP_VIEW)) {
                query = query->src[0];
            }
            name = query ? ggml_get_name(query) : "";
        }
        const auto separator = name.rfind('-');
        if (separator == name.npos) {
            return !ask;
        }
        int index = -1;
        const auto end = name.data() + name.size();
        const auto parsed = std::from_chars(name.data() + separator + 1, end, index);
        if (parsed.ec != std::errc{} || parsed.ptr != end || index < 0 || index >= self.layer_count) {
            return !ask;
        }
        name.remove_suffix(name.size() - separator);
        auto & layer = self.layers[index];
        if (layer.attention.wants(tensor, name)) {
            if (!ask) {
                layer.attention.read(tensor, name);
            }
            return true;
        }
        if (tensor->ne[0] == 2048 && name == "ffn_inp") {
            return collect(tensor->src[1], layer.residual, ask);
        }
        if (tensor->ne[0] == 2048 && name == "l_out") {
            return collect(tensor, layer.output, ask);
        }
        if (index == 0 && tensor->ne[0] == 2048 && name == "ffn_norm") {
            return collect(tensor, self.input, ask);
        }
        if (index == 0 && tensor->ne[0] == 6144 && name == "ffn_up") {
            return collect(tensor, self.up, ask);
        }
        if (index == 0 && tensor->ne[0] == 2048 && name == "ffn_out") {
            return collect(tensor, self.output, ask);
        }
        return !ask;
    }

    static bool collect(const ggml_tensor * tensor, std::vector<float> & data, bool ask) {
        if (!tensor || tensor->type != GGML_TYPE_F32 || ggml_nrows(tensor) != positions ||
            !ggml_is_contiguous(tensor)) {
            return !ask;
        }
        if (!ask) {
            data.resize(ggml_nelements(tensor));
            ggml_backend_tensor_get(tensor, data.data(), 0, ggml_nbytes(tensor));
        }
        return true;
    }

    void write_tensor(const char * name, const std::vector<float> & data) const {
        write_tensor(directory / name, data);
    }

    static void write_tensor(const std::filesystem::path & path, const std::vector<float> & data) {
        std::ofstream file(path, std::ios::binary);
        file.exceptions(std::ios::failbit | std::ios::badbit);
        file.write(reinterpret_cast<const char *>(data.data()), data.size() * sizeof(float));
        file.close();
    }

    std::filesystem::path directory;
    std::vector<float> input;
    std::vector<float> up;
    std::vector<float> output;
    struct layer_capture {
        std::vector<float> residual;
        std::vector<float> output;
        voxt_verify_attention_capture attention;
    };
    std::array<layer_capture, target_layers> layers;
    std::vector<float> logits;
    int layer_count = 1;
    bool active = false;
    bool saved = false;
};
