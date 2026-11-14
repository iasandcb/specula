#include "inflate_bridge.h"
#include <stdlib.h>
#include <zlib.h>

struct inflate_session {
    z_stream stream;
    int chunk_done;
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

int inflate_session_read(inflate_session *session, const uint8_t *input, size_t input_len, int provide_input,
                         uint8_t *out, size_t max_out, size_t *written) {
    if (written) *written = 0;
    if (!session || !written || !out || max_out == 0) return -1;
    if (provide_input) {
        if ((input == NULL && input_len > 0) || input_len > 0xffffffffu) return -1;
        session->chunk_done = 0;
        session->stream.next_in = (Bytef *)(input ? input : (const uint8_t *)"");
        session->stream.avail_in = (uInt)input_len;
    }
    if (session->chunk_done) return 1;
    if (max_out > 0xffffffffu) max_out = 0xffffffffu;
    session->stream.next_out = out;
    session->stream.avail_out = (uInt)max_out;
    int status = inflate(&session->stream, Z_NO_FLUSH);
    size_t got = (size_t)max_out - session->stream.avail_out;
    session->stream.next_out = Z_NULL;
    session->stream.avail_out = 0;
    *written = got;
    if (status == Z_STREAM_END) {
        session->chunk_done = 1;
        return got > 0 ? 0 : 1;
    }
    if (status == Z_OK || status == Z_BUF_ERROR) {
        if (got == 0 && session->stream.avail_in == 0) {
            session->chunk_done = 1;
            return 1;
        }
        return 0;
    }
    return -1;
}
