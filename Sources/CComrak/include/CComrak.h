#ifndef ASTRA_COMRAK_H
#define ASTRA_COMRAK_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct AstraComrakDocument AstraComrakDocument;
typedef struct { size_t from, to, inserted; } AstraComrakEdit;
// Callback returns a malloc-owned UTF-8 string, released by the adapter.
typedef char *(*AstraMathRenderer)(void *context, const uint8_t *tex, size_t length, bool display);

AstraComrakDocument *astra_comrak_parse(const uint16_t *source, size_t length,
    const AstraComrakDocument *previous, const AstraComrakEdit *edits, size_t edit_count,
    AstraMathRenderer math, void *context);
// Returns a guarded range in the new revision for a candidate regional parse.
// False asks the caller to use astra_comrak_parse with the complete source.
bool astra_comrak_edit_region(const AstraComrakDocument *document,
    const AstraComrakEdit *edits, size_t edit_count, size_t *from, size_t *to);
// Parses and splices one candidate range into document. False leaves document
// unchanged and asks the caller to retry with a complete parse.
bool astra_comrak_update_region(AstraComrakDocument *document,
    const uint16_t *source, size_t length, size_t base, size_t total_length,
    const AstraComrakEdit *edits, size_t edit_count,
    AstraMathRenderer math, void *context);
void astra_comrak_document_free(AstraComrakDocument *document);
// Manifest mode is 0 for none, 1 for the initial complete block sequence and
// 2 for the changed interval relative to the previous parsed document.
char *astra_comrak_query(const AstraComrakDocument *document, int64_t revision,
    size_t from, size_t to, uint8_t manifest_mode, bool html, bool fragments);
void astra_comrak_string_free(char *string);
char *astra_comrak_error(void);
#endif
