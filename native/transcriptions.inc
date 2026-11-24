// Included in server-context.cpp to reuse its queue and model state.
static std::string voxt_trim(const std::string & value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" : value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}

static std::string voxt_ascii_lower(std::string value) {
    for (auto & letter : value) {
        if (letter >= 'A' && letter <= 'Z') {
            letter += 'a' - 'A';
        }
    }
    return value;
}

static std::string voxt_language(std::string value) {
    static const std::map<std::string, std::string> languages = {
        {"ar", "Arabic"}, {"yue", "Cantonese"}, {"zh", "Chinese"}, {"cs", "Czech"},
        {"da", "Danish"}, {"nl", "Dutch"}, {"en", "English"}, {"fil", "Filipino"},
        {"fi", "Finnish"}, {"fr", "French"}, {"de", "German"}, {"el", "Greek"},
        {"hi", "Hindi"}, {"hu", "Hungarian"}, {"id", "Indonesian"}, {"it", "Italian"},
        {"ja", "Japanese"}, {"ko", "Korean"}, {"mk", "Macedonian"}, {"ms", "Malay"},
        {"fa", "Persian"}, {"pl", "Polish"}, {"pt", "Portuguese"}, {"ro", "Romanian"},
        {"ru", "Russian"}, {"es", "Spanish"}, {"sv", "Swedish"}, {"th", "Thai"},
        {"tr", "Turkish"}, {"vi", "Vietnamese"},
    };
    value = voxt_trim(value);
    const auto lower = voxt_ascii_lower(value);
    if (lower == "cn" || lower.rfind("zh-", 0) == 0 || lower.rfind("zh_", 0) == 0) {
        return "Chinese";
    }
    for (const auto & [code, name] : languages) {
        if (lower == code || lower == voxt_ascii_lower(name)) {
            return name;
        }
    }
    return value;
}

static int voxt_budget(const json & fields, double seconds) {
    const auto value = json_value(fields, "max_new_tokens", std::string());
    if (value.empty()) {
        return static_cast<int>(std::clamp(std::ceil(seconds * 10), 128.0, 8192.0));
    }
    int tokens = 0;
    const auto last = value.data() + value.size();
    const auto [end, error] = std::from_chars(value.data(), last, tokens);
    if (error != std::errc() || end != last || tokens < 1 || tokens > 8192) {
        throw std::invalid_argument("max_new_tokens must be an integer from 1 to 8192");
    }
    return tokens;
}

static json voxt_done(server_task_result_cmpl_final & final, const llama_vocab * vocab,
                      std::string language, bool metadata) {
    std::string text = final.content.text;
    const auto generated_ids = voxt_trace_enabled() ? final.tokens : llama_tokens{};
    if (final.stop == STOP_TYPE_EOS && !final.tokens.empty()) {
        final.tokens.pop_back();
    }
    if (final.stopping_word == "voxt_token_loop") {
        voxt_collapse_loop(final.tokens);
        text = common_detokenize(vocab, final.tokens, false);
    }
    constexpr std::string_view marker = "<asr_text>";
    const auto marker_pos = text.find(marker);
    if (marker_pos != std::string::npos && marker_pos >= 9 && text.rfind("language ", 0) == 0) {
        const auto detected = voxt_trim(text.substr(9, marker_pos - 9));
        if (language.empty() && voxt_ascii_lower(detected) != "none") {
            language = voxt_language(detected);
        }
        text.erase(0, marker_pos + marker.size());
    }
    json event = {{"type", "transcript.text.done"}, {"text", text}};
    if (metadata) {
        const auto & stats = final.stats;
        auto & gen = event["generation_metadata"];
        gen = {{"generated_token_count", std::max(0, final.n_decoded - (final.stop == STOP_TYPE_EOS ? 1 : 0))},
               {"language", language.empty() ? json(nullptr) : json(language)},
               {"finish_reason", final.stop == STOP_TYPE_LIMIT ? "length" : "stop"},
               {"verify_round_count", stats.n_draft_verif_steps},
               {"live_verify_round_count", stats.voxt_live_verify_rounds},
               {"proposed_draft_token_count", stats.n_draft_tokens},
               {"accepted_draft_token_count", stats.n_draft_accepted}};
        if (voxt_trace_enabled()) {
            gen["token_ids"] = generated_ids;
            gen["first_verify_rounds"] = stats.voxt_first_rounds;
        }
        if (voxt_profile_enabled()) {
            gen["draft_ms"] = stats.voxt_draft_microseconds / 1000.0;
            gen["target_ms"] = stats.voxt_verify_microseconds / 1000.0;
            gen["draft_context_ms"] = stats.voxt_context_microseconds / 1000.0;
        }
    }
    return event;
}

server_http_res_ptr server_routes::voxt_transcriptions(const server_http_req & req, const std::atomic<bool> & stopping) {
    auto response = create_response();
    response->set_req(&req);
    const auto * vocab = ctx_server.vocab;
    bool metadata = false;
    bool stream = false;
    std::string lang;
    try {
        const auto file = req.files.find("file");
        if (file == req.files.end()) {
            throw std::invalid_argument("file is required");
        }
        const auto & audio = file->second.data;
        if (audio.size() < 12 || std::memcmp(audio.data(), "RIFF", 4) != 0 ||
            std::memcmp(audio.data() + 8, "WAVE", 4) != 0) {
            throw std::invalid_argument("file must be a WAV");
        }
        mtmd_helper_media_meta media = {};
        if (mtmd_helper_get_media_meta(file->second.data.data(), file->second.data.size(), ctx_server.init_opt, &media) != 0 ||
            media.type != MTMD_HELPER_MEDIA_TYPE_AUDIO || media.sample_rate != 16000 || media.duration <= 0 ||
            media.audio_channels != 1 || !std::isfinite(media.duration)) {
            throw std::invalid_argument("file must contain 16 kHz mono audio");
        }
        const auto fields = json::parse(req.body);
        const auto flag = [&](const char * name) { return json_value(fields, name, std::string()) == "true"; };
        stream = flag("stream");
        metadata = flag("include_generation_metadata");
        if (metadata && !stream) {
            throw std::invalid_argument("include_generation_metadata requires stream=true");
        }
        lang = voxt_language(json_value(fields, "language", std::string()));
        const auto context = voxt_trim(json_value(fields, "prompt", std::string()));
        std::string prompt = "<|im_start|>system\n" + context + "<|im_end|>\n<|im_start|>user\n" +
                            get_media_marker() + "<|im_end|>\n<|im_start|>assistant\n";
        if (!lang.empty()) {
            prompt += "language " + lang + "<asr_text>";
        }

        server_task task(SERVER_TASK_TYPE_COMPLETION);
        task.id = response->rd.get_new_id();
        task.tokens = process_mtmd_prompt(ctx_server.mctx, prompt, {file->second.data}, ctx_server.init_opt);
        task.params = server_schema::eval_llama_cmpl_schema(
            vocab, params, meta->logit_bias_eog,
            {{"n_predict", voxt_budget(fields, media.duration)}, {"temperature", 0}, {"cache_prompt", false},
             {"return_tokens", true}});
        task.params.voxt_final = true;
        task.params.voxt_stop_on_loop = flag("stop_on_token_loop");
        task.params.voxt_eos = common_tokenize(vocab, "<|im_end|>", false, true).at(0);
        if (flag("stop_at_end_of_text")) {
            task.params.voxt_eot = common_tokenize(vocab, "<|endoftext|>", false, true).at(0);
        }
        response->rd.post_task(std::move(task));
    } catch (const std::exception & error) {
        response->error(format_error_response(error.what(), ERROR_TYPE_INVALID_REQUEST));
        return response;
    }

    if (!stream) {
        auto result = response->rd.next([&] { return req.should_stop() || stopping.load(); });
        if (result && result->is_error()) {
            response->error(result->to_json());
        } else if (result) {
            auto & final = static_cast<server_task_result_cmpl_final &>(*result);
            response->ok({{"text", voxt_done(final, vocab, lang, false)["text"]}});
        }
        return response;
    }

    response->content_type = "text/event-stream";
    response->headers["Cache-Control"] = "no-cache";
    response->status = 200;
    response->set_next([res = response.get(), vocab, lang, metadata, &stopping](std::string & output) {
        if (res->should_stop() || stopping.load() || !res->rd.has_next()) {
            return false;
        }
        auto result = res->rd.next([] { return true; }, std::chrono::milliseconds(250));
        if (!result) {
            output = ":\n\n";
        } else if (result->is_error()) {
            output = format_oai_sse({{"type", "error"}, {"error", {{"code", "transcription_failed"}}}});
        } else {
            auto & final = static_cast<server_task_result_cmpl_final &>(*result);
            output = format_oai_sse(voxt_done(final, vocab, lang, metadata));
        }
        if (result) {
            output += "data: [DONE]\n\n";
        }
        return true;
    });
    return response;
}
