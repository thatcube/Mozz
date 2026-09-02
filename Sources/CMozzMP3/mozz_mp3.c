#include "include/mozz_mp3.h"

#include <stdlib.h>
#include <string.h>

/*
 * Float output, so the decoder hands back exactly what the analyzer wants and
 * no int16 round-trip sits between the file and the feature vector.
 */
#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"

int mozz_mp3_decode(const unsigned char *data, size_t length,
                    float **samples, mozz_mp3_info *info) {
    if (samples == NULL || info == NULL) return 1;
    *samples = NULL;
    info->sample_rate = 0;
    info->channels = 0;
    info->frames = 0;
    if (data == NULL || length == 0) return 1;

    mp3dec_t decoder;
    mp3dec_init(&decoder);

    /*
     * Grown geometrically rather than sized from the input length: MP3 has no
     * cheap exact sample count without a full scan, and a VBR file's ratio of
     * bytes to samples varies across the file.
     */
    size_t capacity = 0;
    size_t used = 0;
    float *output = NULL;

    float pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
    const unsigned char *cursor = data;
    size_t remaining = length;

    while (remaining > 0) {
        mp3dec_frame_info_t frame;
        int decoded = mp3dec_decode_frame(&decoder, cursor, (int)remaining, pcm, &frame);
        if (frame.frame_bytes <= 0) break;   /* No frame found in what is left. */

        cursor += frame.frame_bytes;
        remaining -= (size_t)frame.frame_bytes;

        if (decoded <= 0) continue;          /* A header-only or skipped frame. */

        if (info->sample_rate == 0) {
            info->sample_rate = frame.hz;
            info->channels = frame.channels;
        } else if (frame.hz != info->sample_rate || frame.channels != info->channels) {
            /*
             * A file that changes rate or channel count partway is not something
             * to average over: the samples either side mean different things.
             * Stop at the change and analyze what came before it.
             */
            break;
        }

        size_t produced = (size_t)decoded * (size_t)frame.channels;
        if (used + produced > capacity) {
            size_t next = capacity == 0 ? produced * 64 : capacity * 2;
            while (next < used + produced) next *= 2;
            float *grown = (float *)realloc(output, next * sizeof(float));
            if (grown == NULL) {
                free(output);
                return 2;
            }
            output = grown;
            capacity = next;
        }
        memcpy(output + used, pcm, produced * sizeof(float));
        used += produced;
    }

    if (output == NULL || used == 0 || info->channels <= 0) {
        free(output);
        info->sample_rate = 0;
        info->channels = 0;
        return 1;
    }

    info->frames = used / (size_t)info->channels;
    *samples = output;
    return 0;
}

void mozz_mp3_free(float *samples) {
    free(samples);
}
