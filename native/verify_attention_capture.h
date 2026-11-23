#pragma once

#include "ggml-backend.h"
#include "json.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

class voxt_verify_attention_capture {
public:
    bool wants(const ggml_tensor * node) const {
        if (!output.bytes.empty()) {
            return false;
        }
        const char * name = ggml_get_name(node);
        const auto * query = node->src[0];
        return (node->op == GGML_OP_FLASH_ATTN_EXT && query && query->ne[0] == 128 &&
                query->ne[1] == 8 && query->ne[2] == 16 && query->ne[3] == 1) ||
               std::strcmp(name, "kq-0") == 0 || std::strcmp(name, "kq_soft_max-0") == 0 ||
               std::strcmp(name, "kqv-0") == 0 || std::strcmp(name, "Kcur-0") == 0 ||
               std::strcmp(name, "Vcur-0") == 0;
    }

    void read(const ggml_tensor * node) {
        const char * name = ggml_get_name(node);
        if (node->op == GGML_OP_FLASH_ATTN_EXT) {
            flash = true;
            q.read(node->src[0]);
            k.read(node->src[1]);
            v.read(node->src[2]);
            mask.read(node->src[3]);
            rows.read(node->src[5]);
            output.read(node);
            std::memcpy(&scale, node->op_params, sizeof(scale));
        } else if (std::strcmp(name, "kq-0") == 0) {
            k.read(node->src[0]);
            q.read(node->src[1]);
        } else if (std::strcmp(name, "kq_soft_max-0") == 0) {
            mask.read(node->src[1]);
            std::memcpy(&scale, node->op_params, sizeof(scale));
        } else if (std::strcmp(name, "kqv-0") == 0) {
            v.read(node->src[0]);
            output.read(node);
        } else if (std::strcmp(name, "Kcur-0") == 0) {
            current_k.read(node);
        } else if (std::strcmp(name, "Vcur-0") == 0) {
            current_v.read(node);
        }
    }

    void save(const std::filesystem::path & directory) const {
        if (q.bytes.empty() || k.bytes.empty() || v.bytes.empty() || mask.bytes.empty() || output.bytes.empty()) {
            return;
        }
        common_json manifest = {{"flash", flash}, {"scale", scale}};
        for (const auto & item : std::array<std::pair<const char *, const tensor *>, 8>{{
                 {"q", &q}, {"k", &k}, {"v", &v}, {"mask", &mask}, {"attention_output", &output}, {"kv_rows", &rows},
                 {"current_k", &current_k}, {"current_v", &current_v},
             }}) {
            if (!item.second->bytes.empty()) {
                manifest[item.first] = item.second->save(directory, item.first);
            }
        }
        std::ofstream file(directory / "attention.json");
        file.exceptions(std::ios::failbit | std::ios::badbit);
        file << manifest.dump(2) << '\n';
        file.close();
    }

private:
    struct tensor {
        std::vector<uint8_t> bytes;
        std::vector<int64_t> shape;
        const char * dtype = nullptr;

        void read(const ggml_tensor * source) {
            if (!source || !source->buffer || source->ne[3] != 1) {
                return;
            }
            switch (source->type) {
                case GGML_TYPE_F16: dtype = "<f2"; break;
                case GGML_TYPE_F32: dtype = "<f4"; break;
                case GGML_TYPE_I32: dtype = "<i4"; break;
                default: return;
            }
            const size_t scalar = ggml_type_size(source->type);
            shape = {source->ne[3], source->ne[2], source->ne[1], source->ne[0]};
            bytes.resize(ggml_nelements(source) * scalar);
            if (ggml_is_contiguous(source)) {
                ggml_backend_tensor_get(source, bytes.data(), 0, bytes.size());
                return;
            }
            // A cache view can interleave heads or transpose the context and head dimensions.
            std::vector<uint8_t> raw(ggml_nbytes(source));
            ggml_backend_tensor_get(source, raw.data(), 0, raw.size());
            auto * dest = bytes.data();
            for (int64_t h = 0; h < source->ne[2]; ++h) {
                for (int64_t r = 0; r < source->ne[1]; ++r) {
                    for (int64_t i = 0; i < source->ne[0]; ++i) {
                        const size_t offset = h * source->nb[2] + r * source->nb[1] + i * source->nb[0];
                        std::memcpy(dest, raw.data() + offset, scalar);
                        dest += scalar;
                    }
                }
            }
        }

        common_json save(const std::filesystem::path & directory, const char * name) const {
            const std::string filename = std::string(name) + ".bin";
            std::ofstream file(directory / filename, std::ios::binary);
            file.exceptions(std::ios::failbit | std::ios::badbit);
            file.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
            file.close();
            return {{"file", filename}, {"shape", shape}, {"dtype", dtype}};
        }
    };

    tensor q, k, v, mask, output, rows, current_k, current_v;
    float scale = 0;
    bool flash = false;
};
