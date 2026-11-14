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
void inflate_session_free(void *pointer);
