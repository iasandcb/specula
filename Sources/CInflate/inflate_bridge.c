#include "inflate_bridge.h"
#include <stdlib.h>
#include <zlib.h>

struct inflate_session {
    z_stream stream;
};

inflate_session *inflate_session_create(void) {
    inflate_session *session = calloc(1, sizeof(*session));
    if (!session) return NULL;
    if (inflateInit(&session->stream) != Z_OK) {
        free(session);
        return NULL;
    }
    return session;
}

void inflate_session_destroy(inflate_session *session) {
    if (!session) return;
    inflateEnd(&session->stream);
    free(session);
}

void inflate_session_free(void *pointer) { free(pointer); }

inflate_chunk inflate_session_process(inflate_session *session, const uint8_t *input, size_t input_len) {
    inflate_chunk chunk = {0};
    if (!session || (input == NULL && input_len > 0) || input_len > 0xffffffffu) {
        chunk.status = -1;
        return chunk;
    }
    size_t capacity = input_len * 8 + 64;
    if (capacity < 256) capacity = 256;
    uint8_t *buffer = malloc(capacity);
    if (!buffer) {
        chunk.status = -1;
        return chunk;
    }
    session->stream.next_in = (Bytef *)(input ? input : (const uint8_t *)"");
    session->stream.avail_in = (uInt)input_len;
    size_t produced = 0;
    while (1) {
        if (capacity - produced < 4096) {
            size_t grown = capacity * 2;
            uint8_t *next = realloc(buffer, grown);
            if (!next) {
                free(buffer);
                chunk.status = -1;
                return chunk;
            }
            buffer = next;
            capacity = grown;
        }
        uInt room = (uInt)((capacity - produced) > (1u << 20) ? (1u << 20) : (capacity - produced));
        session->stream.next_out = buffer + produced;
        session->stream.avail_out = room;
        int status = inflate(&session->stream, Z_NO_FLUSH);
        produced += (size_t)(room - session->stream.avail_out);
        if (status == Z_STREAM_END) break;
        if (status == Z_OK || status == Z_BUF_ERROR) {
            // More output can still be pending when the buffer filled exactly.
            if (session->stream.avail_in == 0 && session->stream.avail_out > 0) break;
            continue;
        }
        free(buffer);
        chunk.status = -1;
        return chunk;
    }
    chunk.bytes = buffer;
    chunk.count = produced;
    chunk.status = 0;
    return chunk;
}
