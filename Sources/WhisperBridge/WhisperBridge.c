#include "WhisperBridge.h"

#include <ggml-backend.h>
#include <whisper.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct OWWhisperContext {
    struct whisper_context *context;
    char *language;
    int threads;
};

static pthread_once_t ow_backend_once = PTHREAD_ONCE_INIT;

static void ow_load_backends(void) {
    ggml_backend_load_all();
}

static char *ow_strdup(const char *value) {
    if (value == NULL) {
        value = "";
    }
    const size_t length = strlen(value);
    char *copy = (char *) malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, length + 1);
    return copy;
}

static void ow_set_error(char **error_message, const char *message) {
    if (error_message == NULL) {
        return;
    }
    *error_message = ow_strdup(message);
}

static bool ow_run_full(
    OWWhisperContext *wrapper,
    const float *samples,
    int sample_count,
    OWWhisperTranscribeOptions options,
    const char *initial_prompt,
    char **error_message
) {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = options.threads > 0 ? options.threads : wrapper->threads;
    params.max_tokens = options.max_tokens;
    params.audio_ctx = options.audio_ctx;
    params.no_timestamps = options.no_timestamps;
    params.single_segment = options.single_segment;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.translate = false;
    params.temperature_inc = 0.0f;
    params.suppress_nst = options.suppress_nst;
    params.language = wrapper->language;
    params.greedy.best_of = 1;
    if (initial_prompt != NULL && initial_prompt[0] != '\0') {
        params.initial_prompt = initial_prompt;
    }

    whisper_reset_timings(wrapper->context);
    if (whisper_full(wrapper->context, params, samples, sample_count) != 0) {
        ow_set_error(error_message, "whisper_full failed");
        return false;
    }
    return true;
}

OWWhisperContext *ow_whisper_create(
    const char *model_path,
    const char *language,
    int threads,
    bool use_gpu,
    bool flash_attn,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (model_path == NULL || model_path[0] == '\0') {
        ow_set_error(error_message, "model_path is empty");
        return NULL;
    }

    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = use_gpu;
    context_params.flash_attn = flash_attn;

    pthread_once(&ow_backend_once, ow_load_backends);

    struct whisper_context *context = whisper_init_from_file_with_params(model_path, context_params);
    if (context == NULL) {
        ow_set_error(error_message, "failed to initialize whisper context");
        return NULL;
    }

    OWWhisperContext *wrapper = (OWWhisperContext *) calloc(1, sizeof(OWWhisperContext));
    if (wrapper == NULL) {
        whisper_free(context);
        ow_set_error(error_message, "failed to allocate whisper wrapper");
        return NULL;
    }

    wrapper->context = context;
    wrapper->language = ow_strdup(language == NULL || language[0] == '\0' ? "auto" : language);
    wrapper->threads = threads > 0 ? threads : 4;
    if (wrapper->language == NULL) {
        ow_whisper_free_context(wrapper);
        ow_set_error(error_message, "failed to allocate language string");
        return NULL;
    }

    return wrapper;
}

char *ow_whisper_transcribe(
    OWWhisperContext *wrapper,
    const float *samples,
    int sample_count,
    OWWhisperTranscribeOptions options,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (wrapper == NULL || wrapper->context == NULL) {
        ow_set_error(error_message, "whisper context is null");
        return NULL;
    }
    if (samples == NULL || sample_count <= 0) {
        return ow_strdup("");
    }

    if (!ow_run_full(wrapper, samples, sample_count, options, NULL, error_message)) {
        return NULL;
    }

    const int segment_count = whisper_full_n_segments(wrapper->context);
    size_t total_length = 0;
    for (int i = 0; i < segment_count; i++) {
        const char *segment = whisper_full_get_segment_text(wrapper->context, i);
        if (segment != NULL) {
            total_length += strlen(segment);
        }
    }

    char *result = (char *) calloc(total_length + 1, sizeof(char));
    if (result == NULL) {
        ow_set_error(error_message, "failed to allocate transcription result");
        return NULL;
    }

    size_t offset = 0;
    for (int i = 0; i < segment_count; i++) {
        const char *segment = whisper_full_get_segment_text(wrapper->context, i);
        if (segment == NULL) {
            continue;
        }
        const size_t segment_length = strlen(segment);
        memcpy(result + offset, segment, segment_length);
        offset += segment_length;
    }
    result[offset] = '\0';
    return result;
}

OWWhisperSegmentResult ow_whisper_transcribe_segments(
    OWWhisperContext *wrapper,
    const float *samples,
    int sample_count,
    OWWhisperTranscribeOptions options,
    const char *initial_prompt,
    char **error_message
) {
    OWWhisperSegmentResult empty = { NULL, 0 };
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (wrapper == NULL || wrapper->context == NULL) {
        ow_set_error(error_message, "whisper context is null");
        return empty;
    }
    if (samples == NULL || sample_count <= 0) {
        return empty;
    }

    if (!ow_run_full(wrapper, samples, sample_count, options, initial_prompt, error_message)) {
        return empty;
    }

    const int segment_count = whisper_full_n_segments(wrapper->context);
    if (segment_count <= 0) {
        return empty;
    }

    OWWhisperSegment *segments = (OWWhisperSegment *) calloc(segment_count, sizeof(OWWhisperSegment));
    if (segments == NULL) {
        ow_set_error(error_message, "failed to allocate segment result");
        return empty;
    }

    int written = 0;
    for (int i = 0; i < segment_count; i++) {
        const char *text = whisper_full_get_segment_text(wrapper->context, i);
        if (text == NULL) {
            continue;
        }
        char *text_copy = ow_strdup(text);
        if (text_copy == NULL) {
            OWWhisperSegmentResult partial = { segments, written };
            ow_whisper_free_segment_result(partial);
            ow_set_error(error_message, "failed to allocate segment text");
            return empty;
        }
        segments[written].start_ms = whisper_full_get_segment_t0(wrapper->context, i) * 10;
        segments[written].end_ms = whisper_full_get_segment_t1(wrapper->context, i) * 10;
        segments[written].text = text_copy;
        written += 1;
    }

    OWWhisperSegmentResult result = { segments, written };
    return result;
}

void ow_whisper_free_context(OWWhisperContext *wrapper) {
    if (wrapper == NULL) {
        return;
    }
    if (wrapper->context != NULL) {
        whisper_free(wrapper->context);
    }
    if (wrapper->language != NULL) {
        free(wrapper->language);
    }
    free(wrapper);
}

void ow_whisper_free_string(char *string) {
    if (string != NULL) {
        free(string);
    }
}

void ow_whisper_free_segment_result(OWWhisperSegmentResult result) {
    if (result.segments == NULL) {
        return;
    }
    for (int i = 0; i < result.segment_count; i++) {
        if (result.segments[i].text != NULL) {
            free(result.segments[i].text);
        }
    }
    free(result.segments);
}
