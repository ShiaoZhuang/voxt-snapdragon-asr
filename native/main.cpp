#include "arg.h"
#include "common.h"
#include "log.h"
#include "ggml-backend.h"
#include "server-context.h"
#include "server-http.h"

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#else
#include <signal.h>
#include <unistd.h>
#endif

namespace fs = std::filesystem;

static std::string model_file(const std::string & directory, const std::string & name) {
    if (directory.empty()) {
        throw std::invalid_argument("--model-directory is required");
    }
    const auto path = fs::u8path(directory) / name;
    if (!fs::is_regular_file(path)) {
        throw std::invalid_argument("missing model file: " + path.u8string());
    }
    return path.u8string();
}

static int run(const std::vector<std::string> & arguments) {
    if (arguments.size() == 2 && arguments[1] == "--help") {
        std::cout << "qwen3_asr_server --supervised --host 127.0.0.1 --port 0 "
                     "--model-directory DIR [--draft-model-path DIR --draft-bits 4|6|8] "
                     "[--backend auto|cpu|opencl] [--cache-limit-mb MB]\n";
        return 0;
    }

    std::string directory, draft_directory, bits = "8", port = "0";
    const char * backend_setting = std::getenv("VOXT_ASR_BACKEND");
    std::string backend = backend_setting ? backend_setting : "auto";
    if (arguments.size() == 2 && arguments[1] == "--list-devices") {
        common_init();
        ggml_backend_load_all();
        common_print_available_devices();
        return 0;
    }
    bool supervised = false;
    for (size_t i = 1; i < arguments.size(); ++i) {
        const auto & flag = arguments[i];
        if (flag == "--supervised") {
            supervised = true;
            continue;
        }
        if (++i == arguments.size()) {
            throw std::invalid_argument("missing value for " + flag);
        }
        const auto & value = arguments[i];
        if (flag == "--model-directory") {
            directory = value;
        } else if (flag == "--draft-model-path") {
            draft_directory = value;
        } else if (flag == "--draft-bits") {
            bits = value;
        } else if (flag == "--port") {
            port = value;
        } else if (flag == "--backend") {
            backend = value;
        } else if ((flag == "--host" && value == "127.0.0.1") ||
                   (flag == "--model-kind" && value == "qwen3_asr") ||
                   flag == "--startup-timeout-s" || flag == "--cache-limit-mb" ||
                   flag == "--first-decode-ms" || flag == "--decode-interval-ms" ||
                   flag == "--max-segment-seconds") {
            // The Voxt parent owns the startup deadline and Final chunking.
            // ggml's allocation sizes are fixed by the model and context.
        } else {
            throw std::invalid_argument("unsupported option " + flag + " " + value);
        }
    }

    if (!supervised || (bits != "4" && bits != "6" && bits != "8") ||
        (backend != "auto" && backend != "cpu" && backend != "opencl")) {
        throw std::invalid_argument("invalid supervised, Draft bits or backend option");
    }

    constexpr auto model_name = "Qwen3-ASR-1.7B";
    std::vector<std::string> options = {
        arguments.front(), "--model", model_file(directory, "target.gguf"),
        "--mmproj", model_file(directory, "mmproj.gguf"),
        "--alias", model_name, "--host", "127.0.0.1", "--port", port,
        "--ctx-size", "8192", "--parallel", "1", "--temp", "0",
        "--no-context-shift", "--fit", "off", "--no-webui",
    };
    if (!draft_directory.empty()) {
        options.insert(options.end(), {"--model-draft", model_file(draft_directory, "draft-" + bits + ".gguf"),
                                        "--spec-type", "draft-dflash", "--spec-draft-n-max", "7",
                                        "--spec-draft-p-min", "0"});
    }
    if (backend == "cpu") {
        options.insert(options.end(), {"--device", "none", "--n-gpu-layers", "0", "--no-mmproj-offload",
                                        "--spec-draft-device", "none", "--spec-draft-ngl", "0"});
    } else if (backend == "opencl") {
        options.insert(options.end(), {"--device", "GPUOpenCL", "--n-gpu-layers", "all",
                                        "--spec-draft-device", "GPUOpenCL", "--spec-draft-ngl", "all",
                                        "--mmproj-device", "GPUOpenCL"});
    }
    std::vector<char *> option_values;
    for (auto & option : options) {
        option_values.push_back(option.data());
    }

#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif
    common_init();
    common_params params;
    if (!common_params_parse(static_cast<int>(option_values.size()), option_values.data(), params, LLAMA_EXAMPLE_SERVER)) {
        return 2;
    }

    llama_backend_init();
    {
        server_context context;
        server_routes routes(params, context);
        server_http_context http;
        if (!http.init(params) || !context.load_model(params)) {
            return 1;
        }
        routes.update_meta(context);
        std::atomic<bool> stopping = false;
        http.post("/v1/audio/transcriptions", [&](const server_http_req & request) {
            return routes.voxt_transcriptions(request, stopping);
        });
        http.is_ready.store(true);
        if (!http.start()) {
            return 1;
        }

#ifdef _WIN32
        const auto pid = GetCurrentProcessId();
#else
        const auto pid = getpid();
#endif
        std::thread monitor;
        try {
            context.start_loop([&] {
                std::cout << json({{"event", "ready"}, {"host", "127.0.0.1"}, {"port", http.port},
                                   {"model_name", model_name}, {"server_pid", pid}}).dump() << std::endl;
                monitor = std::thread([&] {
                    for (std::string line; std::getline(std::cin, line);) {
                        try {
                            const auto message = json::parse(line);
                            if (message.is_object() && message.contains("command") && message["command"] == "shutdown") {
                                break;
                            }
                        } catch (const common_json_error &) {
                            // Ignore invalid control lines. EOF still shuts down the process.
                        }
                    }
                    stopping.store(true);
                    context.terminate();
                });
            });
        } catch (const std::exception & error) {
            std::cerr << "qwen3_asr_server: " << error.what() << std::endl;
            std::exit(1);
        }
        http.stop();
        http.join();
        monitor.join();
    }
    llama_backend_free();
    common_log_flush(common_log_main());
    return 0;
}

int main(int argc, char ** argv) {
    try {
#ifdef _WIN32
        const auto free_argv = [](wchar_t ** args) { LocalFree(args); };
        int count = 0;
        std::unique_ptr<wchar_t *, decltype(free_argv)> wide(CommandLineToArgvW(GetCommandLineW(), &count), free_argv);
        if (!wide) {
            throw std::runtime_error("cannot read command line");
        }
        std::vector<std::string> converted;
        for (int i = 0; i < count; ++i) {
            converted.push_back(fs::path(wide.get()[i]).u8string());
        }
        return run(converted);
#else
        return run(std::vector<std::string>(argv, argv + argc));
#endif
    } catch (const std::exception & error) {
        std::cerr << "qwen3_asr_server: " << error.what() << '\n';
        return 2;
    }
}
