#include "raft_markdown.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* Development-only ASan/UBSan driver. Input is repeated little-endian uint32
 * lengths followed by that many original UTF16 units, not null-terminated text. */
int main(void) {
    unsigned char header[4];
    size_t count = 0;
    while (fread(header, 1, 4, stdin) == 4) {
        uint32_t units = (uint32_t)header[0] | (uint32_t)header[1] << 8
            | (uint32_t)header[2] << 16 | (uint32_t)header[3] << 24;
        if (units > 1024 * 1024) return 2;
        uint16_t *source = malloc((size_t)(units + 1) * sizeof *source);
        if (!source) return 3;
        for (uint32_t i = 0; i < units; i++) {
            unsigned char value[2];
            if (fread(value, 1, 2, stdin) != 2) { free(source); return 4; }
            source[i] = (uint16_t)(value[0] | (unsigned)value[1] << 8);
        }
        source[units] = 0;
        int error = 0;
        RaftMarkdownContext *context = raft_markdown_create(&error);
        if (!context || error) { free(source); return 5; }
        char *json = NULL;
        size_t json_size = 0;
        int result = raft_markdown_parse(context, source, units, &json, &json_size);
        free(source);
        if (result || !json || !json_size) {
            raft_markdown_free(json); raft_markdown_destroy(context); return 6;
        }
        raft_markdown_free(json);
        raft_markdown_destroy(context);
        count++;
    }
    if (ferror(stdin)) return 7;
    fprintf(stderr, "Sanitized %zu independent native parses\n", count);
    return 0;
}
