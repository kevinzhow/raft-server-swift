#ifndef RAFT_MARKDOWN_H
#define RAFT_MARKDOWN_H
#include <stddef.h>
#include <stdint.h>
typedef struct RaftMarkdownContext RaftMarkdownContext;
/* A context is synchronous. The caller serializes access to each context. */
RaftMarkdownContext *raft_markdown_create(const char *bundle_utf8, size_t size, int *error);
/* Source uses original UTF16 units. JSON positions use the same units. */
int raft_markdown_parse(RaftMarkdownContext *context, const uint16_t *source,
    size_t units, char **json_utf8, size_t *json_size);
void raft_markdown_free(void *allocation);
void raft_markdown_destroy(RaftMarkdownContext *context);
/* -1 missing runtime, -2 invalid bundle, -3 parse failure, -4 allocation failure. */
#endif
