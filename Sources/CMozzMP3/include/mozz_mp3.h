#ifndef MOZZ_MP3_H
#define MOZZ_MP3_H

#include <stddef.h>

/*
 * A whole MP3 buffer decoded to interleaved float samples.
 *
 * The narrowest possible surface over minimp3: analysis needs "these bytes, as
 * PCM", and nothing else. No streaming, no seeking, no file handling — the
 * bytes arrive over HTTP and are already in memory.
 */

typedef struct {
    int sample_rate;   /* Hz, as the file declares it. */
    int channels;      /* 1 or 2. */
    size_t frames;     /* Samples PER CHANNEL. */
} mozz_mp3_info;

/*
 * Decode `length` bytes of MP3.
 *
 * On success returns 0, writes an interleaved float buffer to `*samples` (the
 * caller owns it and must pass it to `mozz_mp3_free`), and fills `info`.
 * Returns non-zero and leaves `*samples` NULL when the input holds no decodable
 * frames.
 *
 * Leading garbage — ID3 tags, a partial frame from a range request — is skipped
 * by minimp3's own frame search rather than parsed here.
 */
int mozz_mp3_decode(const unsigned char *data, size_t length,
                    float **samples, mozz_mp3_info *info);

void mozz_mp3_free(float *samples);

#endif /* MOZZ_MP3_H */
