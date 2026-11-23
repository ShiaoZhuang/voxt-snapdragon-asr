#pragma once

#include "common.h"
#include "ggml-backend.h"
#include "json.h"
#include "log.h"

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
        active = true;
    }

    void finish(bool decoded, const std::array<int, positions> & tokens, const std::array<int, positions> & pos) {
        active = false;
        if (!decoded || input.empty() || up.empty()) {
            return;
        }
        saved = true;
        try {
            if (!std::filesystem::create_directory(directory)) {
                throw std::runtime_error("capture directory already exists");
            }
            write_tensor("ffn_norm.f32", input);
            write_tensor("ffn_up.f32", up);
            std::ofstream manifest(directory / "capture.json");
            manifest.exceptions(std::ios::failbit | std::ios::badbit);
            manifest << common_json({
                {"layer", 0}, {"dtype", "float32-le"},
                {"tokens", std::vector<int>(tokens.begin(), tokens.end())},
                {"positions", std::vector<int>(pos.begin(), pos.end())},
                {"input_shape", common_json::array({positions, 2048})},
                {"output_shape", common_json::array({positions, 6144})},
            }).dump(2) << '\n';
            manifest.close();
        } catch (const std::exception & error) {
            LOG_ERR("Voxt verification capture: %s\n", error.what());
        }
    }

private:
    static bool eval(ggml_tensor * tensor, bool ask, void * user_data) {
        auto & self = *static_cast<voxt_verify_capture *>(user_data);
        if (self.active && tensor->type == GGML_TYPE_F32 && ggml_nrows(tensor) == positions && ggml_is_contiguous(tensor)) {
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
    bool active = false;
    bool saved = false;
};
