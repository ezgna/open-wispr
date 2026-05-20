#ifndef OPENWISPR_WHISPER_BRIDGE_H
#define OPENWISPR_WHISPER_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OWWhisperContext OWWhisperContext;

typedef struct OWWhisperTranscribeOptions {
    int threads;
    int max_tokens;
    int audio_ctx;
    bool no_timestamps;
    bool single_segment;
    bool suppress_nst;
} OWWhisperTranscribeOptions;

OWWhisperContext *ow_whisper_create(
    const char *model_path,
    const char *language,
    int threads,
    bool use_gpu,
    bool flash_attn,
    char **error_message
);

char *ow_whisper_transcribe(
    OWWhisperContext *context,
    const float *samples,
    int sample_count,
    OWWhisperTranscribeOptions options,
    char **error_message
);

void ow_whisper_free_context(OWWhisperContext *context);
void ow_whisper_free_string(char *string);

#ifdef __cplusplus
}
#endif

#endif
