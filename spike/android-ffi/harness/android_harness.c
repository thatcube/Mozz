// Mozz Android FFI spike — native host harness.
//
// The mirror of `spike/windows-ffi/Harness` (a C# program that P/Invokes the
// DLL), rewritten in plain C so it can be cross-compiled with the Android NDK
// and run *on the device* — an Android emulator in CI, or a real phone over
// adb. See ../README.md for what this proves and why.
//
// It deliberately does NOT link MozzFFI. It `dlopen`s libMozzFFI.so and resolves
// every entry point with `dlsym`, exactly the way a JNI shim (or a Kotlin app
// using it) would. That makes the run a real test of two things a static symbol
// dump cannot show: that the shared object actually *loads* on Android with all
// its transitive Swift-runtime and SQLite dependencies resolved, and that its C
// ABI holds when called from a foreign toolchain.
//
// Exit code is 0 only if every gate passes, so CI goes red on a real failure
// rather than printing a sad number and moving on — the same contract as the
// Windows harness.

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The C ABI exported by Sources/MozzFFI. Keep these in lockstep with the
// @_cdecl signatures; a mismatch here is a bug in the harness, not the core.
typedef char *(*probe_fn)(void);
typedef char *(*benchmark_fn)(const char *db_path, int32_t track_count);
typedef char *(*search_fn)(const char *db_path, const char *query, int32_t limit);
typedef char *(*hpke_fn)(void);
typedef char *(*continuity_fn)(const char *fixtures_json);
typedef void (*free_fn)(char *ptr);
typedef int64_t (*session_open_fn)(const char *db_path);
typedef char *(*session_call_fn)(int64_t handle, const char *request_json);
typedef int32_t (*session_close_fn)(int64_t handle);

static free_fn mozz_free = NULL;

// The published iOS numbers this spike is measured against (iPhone 17 Pro Max,
// 100k tracks). Not pass/fail on their own — different hardware — but an
// order-of-magnitude regression means the boundary design is wrong.
static const double IOS_SEARCH_P50_MS = 7.9;
static const double IOS_SEARCH_P95_MS = 15.7;
static const double IOS_COLD_OPEN_MS = 66.4;
static const double IOS_PAGE_FETCH_MS = 3.8;

// The hard product requirement, independent of platform.
static const double SEARCH_P95_BUDGET_MS = 100.0;

// --- tiny JSON scraping ------------------------------------------------------
//
// The envelopes are encoded with JSONEncoder(.sortedKeys): compact, no spaces,
// so `"key":value` appears verbatim and a substring search is enough. This is a
// harness, not a parser — every key we read is unique across the document, and
// we print the raw JSON alongside so nothing is hidden behind the scrape.

static double json_num(const char *json, const char *key) {
    char pat[128];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(json, pat);
    if (!p) return NAN;
    p += strlen(pat);
    return atof(p);
}

static int json_bool_true(const char *json, const char *key) {
    char pat[160];
    snprintf(pat, sizeof pat, "\"%s\":true", key);
    return strstr(json, pat) != NULL;
}

// Count occurrences of a literal needle in a haystack.
static int count_occurrences(const char *haystack, const char *needle) {
    int n = 0;
    const char *p = haystack;
    size_t len = strlen(needle);
    while ((p = strstr(p, needle)) != NULL) {
        n++;
        p += len;
    }
    return n;
}

// Is the envelope an "ok" one? Returns 1 and leaves the caller to inspect the
// payload; returns 0 and prints the error otherwise.
static int envelope_ok(const char *call, const char *json) {
    if (json == NULL) {
        fprintf(stderr, "  %s returned a null pointer\n", call);
        return 0;
    }
    if (json_bool_true(json, "ok")) return 1;
    fprintf(stderr, "  %s failed: %s\n", call, json);
    return 0;
}

int main(int argc, char **argv) {
    const char *lib_path = (argc > 1) ? argv[1] : "libMozzFFI.so";
    long track_count = (argc > 2) ? strtol(argv[2], NULL, 10) : 100000;
    const char *db_path = (argc > 3) ? argv[3] : "/data/local/tmp/mozz-android-spike.sqlite";
    const char *fixtures_path = (argc > 4) ? argv[4] : NULL;

    int failures = 0;
    char err_buf[512];
    char *failure_msgs[16];
    int failure_count = 0;
#define FAIL(msg)                                                              \
    do {                                                                       \
        if (failure_count < 16) failure_msgs[failure_count++] = strdup(msg);   \
        failures++;                                                            \
    } while (0)

    printf("=== 0. Load: does libMozzFFI.so load on Android with all its deps? ===\n");
    printf("  dlopen %s\n", lib_path);
    void *handle = dlopen(lib_path, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        fprintf(stderr, "  dlopen failed: %s\n", dlerror());
        return 1;
    }

    // Resolve every symbol up front. A missing one here is the static-export
    // check failing at runtime — report all of them, don't stop at the first.
    dlerror();
    probe_fn probe = (probe_fn)dlsym(handle, "mozz_ffi_probe");
    benchmark_fn benchmark = (benchmark_fn)dlsym(handle, "mozz_ffi_benchmark");
    search_fn search = (search_fn)dlsym(handle, "mozz_ffi_search");
    hpke_fn probe_hpke = (hpke_fn)dlsym(handle, "mozz_ffi_probe_hpke");
    continuity_fn verify_continuity = (continuity_fn)dlsym(handle, "mozz_ffi_verify_continuity_hashes");
    mozz_free = (free_fn)dlsym(handle, "mozz_ffi_free_string");
    session_open_fn session_open = (session_open_fn)dlsym(handle, "mozz_session_open");
    session_call_fn session_call = (session_call_fn)dlsym(handle, "mozz_session_call");
    session_close_fn session_close = (session_close_fn)dlsym(handle, "mozz_session_close");

    const char *missing = NULL;
    if (!probe) missing = "mozz_ffi_probe";
    else if (!benchmark) missing = "mozz_ffi_benchmark";
    else if (!search) missing = "mozz_ffi_search";
    else if (!probe_hpke) missing = "mozz_ffi_probe_hpke";
    else if (!verify_continuity) missing = "mozz_ffi_verify_continuity_hashes";
    else if (!mozz_free) missing = "mozz_ffi_free_string";
    else if (!session_open) missing = "mozz_session_open";
    else if (!session_call) missing = "mozz_session_call";
    else if (!session_close) missing = "mozz_session_close";
    if (missing) {
        fprintf(stderr, "  exported symbol missing: %s\n", missing);
        return 1;
    }
    printf("  loaded, and all probe + session ABI symbols resolved\n\n");

    // --- 1. Probe: FTS5 is the decisive gate --------------------------------
    printf("=== 1. Probe: does the core run, and does SQLite have FTS5? ===\n");
    char *probe_json = probe();
    if (envelope_ok("probe", probe_json)) {
        printf("  %s\n", probe_json);
        int fts5_created = json_bool_true(probe_json, "fts5CreateSucceeded");
        printf("  FTS5 create OK  : %s\n", fts5_created ? "true" : "false");
        if (!fts5_created) {
            // The decisive failure. Everything downstream depends on it, so stop
            // here rather than emit confusing follow-on errors.
            FAIL("FTS5 is NOT available in the linked SQLite — Mozz search cannot work on Android as built");
            if (probe_json) mozz_free(probe_json);
            goto report;
        }
    } else {
        FAIL("probe entry point failed");
        if (probe_json) mozz_free(probe_json);
        goto report;
    }
    mozz_free(probe_json);

    // --- 2. Benchmark: the read path, comparable to the iOS numbers ---------
    printf("\n=== 2. Benchmark: generate %ld tracks and measure reads ===\n", track_count);
    char *bench_json = benchmark(db_path, (int32_t)track_count);
    double search_p50 = NAN, search_p95 = NAN, cold_open = NAN, page_fetch = NAN, generation = NAN;
    if (envelope_ok("benchmark", bench_json)) {
        search_p50 = json_num(bench_json, "searchP50Ms");
        search_p95 = json_num(bench_json, "searchP95Ms");
        cold_open = json_num(bench_json, "coldOpenMs");
        page_fetch = json_num(bench_json, "pageFetchMs");
        generation = json_num(bench_json, "generationSeconds");

        printf("  metric                 this platform      iOS (iPhone 17 Pro Max)\n");
        printf("  search p50             %10.1f ms      %10.1f ms\n", search_p50, IOS_SEARCH_P50_MS);
        printf("  search p95             %10.1f ms      %10.1f ms\n", search_p95, IOS_SEARCH_P95_MS);
        printf("  cold open + count      %10.1f ms      %10.1f ms\n", cold_open, IOS_COLD_OPEN_MS);
        printf("  page fetch (100 rows)  %10.1f ms      %10.1f ms\n", page_fetch, IOS_PAGE_FETCH_MS);
        printf("  generation             %10.1f s       %10.1f s\n", generation, 3.9);

        if (!isnan(search_p95) && search_p95 > SEARCH_P95_BUDGET_MS) {
            snprintf(err_buf, sizeof err_buf,
                     "search p95 %.1f ms exceeds the %.0f ms product budget",
                     search_p95, SEARCH_P95_BUDGET_MS);
            FAIL(err_buf);
        }
    } else {
        FAIL("benchmark entry point failed");
    }
    if (bench_json) mozz_free(bench_json);

    // --- 3. Marshalling cost: query time vs JSON encode time ----------------
    printf("\n=== 3. Marshalling cost: DB time vs JSON encode time at the boundary ===\n");
    const char *terms[] = {"Machine", "Golden", "Ocean", "Silent", "Horizon"};
    double total_query = 0, total_encode = 0;
    for (int i = 0; i < 5; i++) {
        char *s = search(db_path, terms[i], 100);
        if (envelope_ok("search", s)) {
            double open_ms = json_num(s, "openMs");
            double query_ms = json_num(s, "queryMs");
            double encode_ms = json_num(s, "encodeMs");
            double bytes = json_num(s, "payloadBytes");
            double tracks = json_num(s, "tracks");
            total_query += query_ms;
            total_encode += encode_ms;
            printf("  %-10s %4.0f tracks   open %6.2f ms   query %7.2f ms   encode %6.2f ms   %6.0f bytes\n",
                   terms[i], tracks, open_ms, query_ms, encode_ms, bytes);
        } else {
            FAIL("search entry point failed");
        }
        if (s) mozz_free(s);
    }
    if (total_query > 0) {
        double encode_share = total_encode / total_query * 100.0;
        printf("\n  encode overhead: %.1f%% of query time (%.2f ms encode vs %.2f ms query)\n",
               encode_share, total_encode, total_query);
        printf("  %s\n", encode_share < 25
                             ? "=> JSON at the boundary is cheap. The coarse-grained design holds."
                             : "=> encode cost is significant; consider a binary boundary format.");
    }

    // --- 4. Session ABI: the production facade, exercised live ---------------
    // The static nm check proves these symbols exist; this proves they work.
    printf("\n=== 4. Session ABI: open the populated library and read through it ===\n");
    int64_t sh = session_open(db_path);
    if (sh > 0) {
        char *counts = session_call(sh, "{\"id\":1,\"cmd\":\"counts\"}");
        if (envelope_ok("session counts", counts)) {
            printf("  counts: %s\n", counts);
        } else {
            FAIL("mozz_session_call(counts) failed");
        }
        if (counts) mozz_free(counts);
        if (session_close(sh) != 1) FAIL("mozz_session_close did not report a live handle");
        printf("  session opened, queried and closed cleanly\n");
    } else {
        FAIL("mozz_session_open returned 0 for the populated database");
    }

    // --- 5. HPKE: can the pairing crypto live in the shared core? -----------
    printf("\n=== 5. HPKE: can the pairing crypto live in the shared core? ===\n");
    char *hpke_json = probe_hpke();
    if (hpke_json) {
        printf("  %s\n", hpke_json);
        if (json_bool_true(hpke_json, "available")) {
            printf("  => ADR-0013 holds on Android: one pairing implementation for every platform.\n");
        } else {
            FAIL("HPKE is unavailable on Android — ADR-0013 cannot put pairing crypto in the shared core");
        }
        mozz_free(hpke_json);
    } else {
        FAIL("HPKE probe returned a null pointer");
    }

    // --- 6. Continuity hashes: byte-identical agreement with iOS ------------
    printf("\n=== 6. Continuity hashes: does Android agree with spec/continuity? ===\n");
    if (fixtures_path == NULL) {
        FAIL("no continuity fixtures path was provided");
    } else {
        FILE *f = fopen(fixtures_path, "rb");
        if (!f) {
            snprintf(err_buf, sizeof err_buf, "could not open fixtures at %s", fixtures_path);
            FAIL(err_buf);
        } else {
            fseek(f, 0, SEEK_END);
            long n = ftell(f);
            fseek(f, 0, SEEK_SET);
            char *buf = malloc((size_t)n + 1);
            size_t got = fread(buf, 1, (size_t)n, f);
            buf[got] = '\0';
            fclose(f);

            char *cases = verify_continuity(buf);
            free(buf);
            if (envelope_ok("verifyContinuityHashes", cases)) {
                int total = count_occurrences(cases, "\"matches\":");
                int matched = count_occurrences(cases, "\"matches\":true");
                printf("  %d of %d continuity fixtures byte-identical with iOS\n", matched, total);
                if (total == 0 || matched != total) {
                    printf("  %s\n", cases);
                    snprintf(err_buf, sizeof err_buf,
                             "%d of %d continuity fixtures mismatch — cross-device resume would fail silently",
                             total - matched, total);
                    FAIL(err_buf);
                } else {
                    printf("  => byte-identical with the Swift/iOS implementation.\n");
                }
            } else {
                FAIL("continuity verification entry point failed");
            }
            if (cases) mozz_free(cases);
        }
    }

report:
    printf("\n");
    if (failure_count == 0) {
        printf("RESULT: PASS — the Swift core builds, loads and runs through a C ABI on Android.\n");
    } else {
        printf("RESULT: FAIL\n");
        for (int i = 0; i < failure_count; i++) {
            printf("  - %s\n", failure_msgs[i]);
            free(failure_msgs[i]);
        }
    }
    dlclose(handle);
    return failures == 0 ? 0 : 1;
}
