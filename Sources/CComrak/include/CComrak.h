#ifndef ASTRA_COMRAK_H
#define ASTRA_COMRAK_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct AstraComrakResult AstraComrakResult;
// Callback returns a malloc-owned UTF-8 string, released by the adapter.
typedef char *(*AstraMathRenderer)(void *context, const uint8_t *tex, size_t length, bool display);

typedef struct {
    const uint8_t *bytes;
    size_t length;
} AstraComrakStringView;
typedef struct {
    size_t id;
    uint8_t kind;
    size_t from, to;
    size_t span_start, span_count;
    AstraComrakStringView html;
} AstraComrakBlockRecord;
typedef struct {
    uint8_t kind;
    size_t from, to;
} AstraComrakSpanRecord;
typedef struct {
    int64_t revision;
    size_t from, to;
    bool has_references;
    const AstraComrakBlockRecord *blocks;
    size_t block_count;
    const AstraComrakSpanRecord *spans;
    size_t span_count;
} AstraComrakResultView;

// Parses one owned source slice. The result owns the byte slices referenced by
// its view and remains valid until the caller frees it. The caller may keep it
// as immutable output storage; Rust retains no parser or document state between calls.
AstraComrakResult *astra_comrak_parse_records(const uint16_t *source, size_t length,
    size_t base, int64_t revision, AstraMathRenderer math, void *context);
bool astra_comrak_result_view(const AstraComrakResult *result, AstraComrakResultView *view);
void astra_comrak_result_free(AstraComrakResult *result);

void astra_comrak_string_free(char *string);
char *astra_comrak_error(void);
#endif
