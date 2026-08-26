/*
 * Proves the generated header describes a library a C compiler can link.
 *
 * A header that merely *generates* is evidence of nothing. It can name a symbol
 * the staticlib does not export, declare a type whose layout the two sides
 * disagree about, or be perfectly correct while the library fails to build for
 * the target at all. None of that surfaces until a shell tries to link it,
 * which on Apple platforms is a long way into the process.
 *
 * So: compile against the header, link the real staticlib, and drive the player
 * across the whole surface. If a signature drifts this stops linking, at the
 * point the change is made rather than the point someone tries to ship it.
 *
 * It needs no fixture file and no audio device. The WAV is built in memory, and
 * the engine falls back to its silent output when no device can be driven at
 * the source rate - which is the path any CI machine takes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mozz_audio.h"

typedef struct {
    unsigned char *bytes;
    size_t length;
    size_t position;
    int closed;
} Stream;

static intptr_t stream_read(void *ctx, uint8_t *buffer, size_t length) {
    Stream *s = (Stream *)ctx;
    size_t remaining = s->length - s->position;
    size_t take = length < remaining ? length : remaining;
    if (take > 0) {
        memcpy(buffer, s->bytes + s->position, take);
        s->position += take;
    }
    return (intptr_t)take;
}

static int64_t stream_seek(void *ctx, int64_t offset, int whence) {
    Stream *s = (Stream *)ctx;
    int64_t base = 0;
    if (whence == 1) base = (int64_t)s->position;
    else if (whence == 2) base = (int64_t)s->length;
    int64_t landed = base + offset;
    if (landed < 0) landed = 0;
    if (landed > (int64_t)s->length) landed = (int64_t)s->length;
    s->position = (size_t)landed;
    return landed;
}

static void stream_close(void *ctx) {
    Stream *s = (Stream *)ctx;
    s->closed = 1;
    free(s->bytes);
}

static void put_u32(unsigned char *o, uint32_t v) {
    o[0]=(unsigned char)(v&0xff); o[1]=(unsigned char)((v>>8)&0xff);
    o[2]=(unsigned char)((v>>16)&0xff); o[3]=(unsigned char)((v>>24)&0xff);
}
static void put_u16(unsigned char *o, uint16_t v) {
    o[0]=(unsigned char)(v&0xff); o[1]=(unsigned char)((v>>8)&0xff);
}

static unsigned char *make_wav(size_t frames, size_t *length_out) {
    size_t data = frames * 2, total = 44 + data;
    unsigned char *out = (unsigned char *)calloc(total, 1);
    if (!out) return NULL;
    memcpy(out, "RIFF", 4);      put_u32(out+4, (uint32_t)(36+data));
    memcpy(out+8, "WAVEfmt ", 8); put_u32(out+16, 16);
    put_u16(out+20, 1); put_u16(out+22, 1);
    put_u32(out+24, 8000); put_u32(out+28, 16000);
    put_u16(out+32, 2); put_u16(out+34, 16);
    memcpy(out+36, "data", 4); put_u32(out+40, (uint32_t)data);
    for (size_t f = 0; f < frames; f++) put_u16(out+44+f*2, 8000);
    *length_out = total;
    return out;
}

static int failures = 0;
static void check(int condition, const char *what) {
    if (condition) printf("  ok   %s\n", what);
    else { printf("  FAIL %s\n", what); failures++; }
}

static int eventually(int (*predicate)(void *), void *ctx) {
    for (int attempt = 0; attempt < 400; attempt++) {
        if (predicate(ctx)) return 1;
        struct timespec pause = {0, 5*1000*1000};
        nanosleep(&pause, NULL);
    }
    return 0;
}

static int is_playing(void *ctx)   { return mozz_player_state((const MozzPlayer *)ctx) == 1; }
static int has_position(void *ctx) { return mozz_player_position_seconds((const MozzPlayer *)ctx) > 0.02; }
static int is_closed(void *ctx)    { return ((Stream *)ctx)->closed; }

int main(void) {
    printf("mozz audio C ABI smoke test\n");

    MozzPlayer *player = mozz_player_new(8000, 1, 8192);
    check(player != NULL, "a player can be created");
    if (!player) return 1;
    check(mozz_player_state(player) == 0, "a new player is idle");

    size_t length = 0;
    unsigned char *wav = make_wav(16000, &length);
    check(wav != NULL, "the fixture was built");
    if (!wav) return 1;

    Stream *stream = (Stream *)calloc(1, sizeof(Stream));
    stream->bytes = wav;
    stream->length = length;

    MozzSource source;
    source.ctx = stream;
    source.read = stream_read;
    source.seek = stream_seek;
    source.close = stream_close;

    mozz_player_play_now(player, source, "wav", 4242, 0.0, false);
    check(eventually(is_playing, player), "the player reaches playing");
    check(mozz_player_current_track(player) == 4242, "it reports the track it was given");
    check(eventually(has_position, player), "position advances");
    check(!mozz_player_has_failed(player), "nothing failed");

    double gains[10] = {0};
    gains[0] = 3.0;
    mozz_player_set_equalizer(player, gains, 0.0, true);
    mozz_player_set_replay_gain(player, 1, -3.0);
    mozz_player_seek(player, 0.25);
    mozz_player_pause(player);
    mozz_player_resume(player);
    check(!mozz_player_has_failed(player), "the controls did not break it");

    mozz_player_stop(player);
    mozz_player_free(player);
    check(eventually(is_closed, stream), "the stream was closed exactly once");
    free(stream);

    mozz_player_pause(NULL);
    mozz_player_free(NULL);
    check(mozz_player_state(NULL) == 0, "a null handle is inert");

    printf(failures == 0 ? "PASSED\n" : "FAILED\n");
    return failures == 0 ? 0 : 1;
}
