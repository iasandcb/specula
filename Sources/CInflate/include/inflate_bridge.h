#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct inflate_session inflate_session;

typedef struct inflate_chunk {
    uint8_t *bytes;
    size_t count;
    int status;
} inflate_chunk;

inflate_session *inflate_session_create(void);
void inflate_session_destroy(inflate_session *session);
/// Inflate the next chunk of one zlib stream. `bytes` is malloc'd on success; free it with inflate_session_free.
inflate_chunk inflate_session_process(inflate_session *session, const uint8_t *input, size_t input_len);
/// Pull the next inflated bytes of the current chunk into `out` (at most `max_out`).
/// Pass `provide_input` non-zero once per rectangle so `input` stays the zlib source until it is consumed.
/// Returns 0 when `*written` bytes are available, 1 when this chunk has no further output, -1 on error.
int inflate_session_read(inflate_session *session, const uint8_t *input, size_t input_len, int provide_input,
                         uint8_t *out, size_t max_out, size_t *written);
void inflate_session_free(void *pointer);
