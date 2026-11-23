#pragma once

#include "common.h"
#include "ggml-backend.h"
#include "json.h"
#include "log.h"
#include "verify_attention_capture.h"

#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

// A diagnostic capture of the first full DFlash verification batch on a single ASR slot.
class voxt_verify_capture {
public:
    static constexpr int positions = 8;

    void configure(common_params & params) {
#ifdef _WIN32
        const auto * path = _wgetenv(L"VOXT_VERIFY_CAPTURE_DIR");
#else
        const auto * path = std::getenv("VOXT_VERIFY_CAPTURE_DIR");
#endif
        if (path && *path && !params.cb_eval && !saved) {
            directory = path;
            params.cb_eval = eval;
            params.cb_eval_user_data = this;
        }
    }

    bool enabled() const { return !directory.empty() && !saved; }

    void begin() {
        input.clear();
        up.clear();
        output.clear();
        residual.clear();
        layer_output.clear();
        attention = {};
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
            if (!residual.empty() && !layer_output.empty()) {
                write_tensor("attention_residual.f32", residual);
                write_tensor("layer_out.f32", layer_output);
            }
            std::ofstream manifest(directory / "capture.json");
            manifest.exceptions(std::ios::failbit | std::ios::badbit);
            manifest << common_json({
                {"layer", 0}, {"dtype", "float32-le"},
                {"tokens", std::vector<int>(tokens.begin(), tokens.end())},
                {"positions", std::vector<int>(pos.begin(), pos.end())},
                {"input_shape", common_json::array({positions, 2048})},
                {"output_shape", common_json::array({positions, 6144})},
                {"ffn_output_shape", common_json::array({positions, 2048})},
            }).dump(2) << '\n';
            manifest.close();
            attention.save(directory);
        } catch (const std::exception & error) {
            LOG_ERR("Voxt verification capture: %s\n", error.what());
        }
    }

private:
    static bool eval(ggml_tensor * tensor, bool ask, void * user_data) {
        auto & self = *static_cast<voxt_verify_capture *>(user_data);
        if (self.active && self.attention.wants(tensor)) {
            if (!ask) {
                self.attention.read(tensor);
            }
            return true;
        }
        if (self.active && tensor->type == GGML_TYPE_F32 && ggml_nrows(tensor) == positions && ggml_is_contiguous(tensor)) {
            if (std::strcmp(ggml_get_name(tensor), "ffn_inp-0") == 0) {
                const auto * residual = tensor->src[1];
                if (residual && residual->type == GGML_TYPE_F32 && ggml_is_contiguous(residual) &&
                    ggml_nelements(residual) == 2048 * positions) {
                    if (!ask) {
                        self.residual.resize(ggml_nelements(residual));
                        ggml_backend_tensor_get(residual, self.residual.data(), 0, ggml_nbytes(residual));
                    }
                    return true;
                }
            }
            auto * data = select(self, tensor);
            if (data) {
                if (!ask) {
                    data->resize(ggml_nelements(tensor));
                    ggml_backend_tensor_get(tensor, data->data(), 0, ggml_nbytes(tensor));
                }
                return true;
            }
        }
        return !ask;
    }

    static std::vector<float> * select(voxt_verify_capture & self, const ggml_tensor * tensor) {
        const char * name = ggml_get_name(tensor);
        if (tensor->ne[0] == 2048 && std::strcmp(name, "ffn_norm-0") == 0) {
            return &self.input;
        }
        if (tensor->ne[0] == 6144 && std::strcmp(name, "ffn_up-0") == 0) {
            return &self.up;
        }
        if (tensor->ne[0] == 2048 && std::strcmp(name, "ffn_out-0") == 0) {
            return &self.output;
        }
        if (tensor->ne[0] == 2048 && std::strcmp(name, "l_out-0") == 0) {
            return &self.layer_output;
        }
        return nullptr;
    }

    void write_tensor(const char * name, const std::vector<float> & data) const {
        std::ofstream file(directory / name, std::ios::binary);
        file.exceptions(std::ios::failbit | std::ios::badbit);
        file.write(reinterpret_cast<const char *>(data.data()), data.size() * sizeof(float));
        file.close();
    }

    std::filesystem::path directory;
    std::vector<float> input;
    std::vector<float> up;
    std::vector<float> output;
    std::vector<float> residual;
    std::vector<float> layer_output;
    voxt_verify_attention_capture attention;
    bool active = false;
    bool saved = false;
};
