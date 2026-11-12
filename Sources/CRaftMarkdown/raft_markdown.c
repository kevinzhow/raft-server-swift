#include "raft_markdown.h"
#include "vendor/md4c.h"
#include "vendor/entity.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* No VM, process-global parser or retained per-message allocations. */
struct RaftMarkdownContext { unsigned initialized; };
typedef struct { char *data; size_t size, capacity; int failed; } Buffer;
typedef struct { unsigned kind, beg, end; char *href; } Range;
typedef struct { Range *items; size_t count, capacity; int failed; } Ranges;

static int reserve(Buffer *b, size_t extra) {
    if (b->failed || extra > SIZE_MAX - b->size - 1) { b->failed = 1; return 0; }
    size_t need = b->size + extra + 1;
    if (need <= b->capacity) return 1;
    size_t capacity = b->capacity ? b->capacity : 128;
    while (capacity < need) {
        if (capacity > SIZE_MAX / 2) { capacity = need; break; }
        capacity *= 2;
    }
    char *data = realloc(b->data, capacity);
    if (!data) { b->failed = 1; return 0; }
    b->data = data; b->capacity = capacity;
    return 1;
}
static void append(Buffer *b, const char *s, size_t n) {
    if (!reserve(b, n)) return;
    memcpy(b->data + b->size, s, n); b->size += n; b->data[b->size] = 0;
}
static void literal(Buffer *b, const char *s) { append(b, s, strlen(s)); }
static void json_unit(Buffer *b, unsigned value) {
    char escaped[7];
    snprintf(escaped, sizeof escaped, "\\u%04x", value & 0xffff);
    append(b, escaped, 6);
}
static void json_codepoint(Buffer *b, unsigned cp) {
    if (cp <= 0xffff) { json_unit(b, cp); return; }
    cp -= 0x10000;
    json_unit(b, 0xd800 + (cp >> 10)); json_unit(b, 0xdc00 + (cp & 1023));
}
static int punctuation(unsigned c) {
    return (c >= 33 && c <= 47) || (c >= 58 && c <= 64)
        || (c >= 91 && c <= 96) || (c >= 123 && c <= 126);
}
static unsigned numeric_reference(unsigned cp) {
    /* micromark-util-decode-numeric-character-reference's invalid code points. */
    if (cp < 9 || cp == 11 || (cp > 13 && cp < 32) || (cp > 126 && cp < 160)
        || (cp >= 0xd800 && cp <= 0xdfff) || (cp >= 0xfdd0 && cp <= 0xfdef)
        || (cp & 0xffff) == 0xffff || (cp & 0xffff) == 0xfffe || cp > 0x10ffff)
        return 0xfffd;
    return cp;
}
static int entity(Buffer *b, const MD_CHAR *s, size_t n, size_t *consumed) {
    char name[64]; size_t len = 0;
    while (len < n && len < sizeof name - 1 && s[len] < 128) {
        name[len] = (char)s[len];
        if (s[len++] == ';') break;
    }
    if (len < 3 || name[len-1] != ';') return 0;
    name[len] = 0;
    if (name[1] == '#') {
        size_t i = 2; unsigned base = 10, cp = 0;
        if (name[i] == 'x' || name[i] == 'X') { base = 16; i++; }
        size_t digits = len - 1 - i;
        if (!digits || digits > (base == 16 ? 6 : 7)) return 0;
        for (; i < len - 1; i++) {
            unsigned c = (unsigned char)name[i], digit;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (base == 16 && c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (base == 16 && c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            else return 0;
            cp = cp * base + digit;
        }
        json_codepoint(b, numeric_reference(cp));
    } else {
        const ENTITY *value = entity_lookup(name, len);
        if (!value) return 0;
        json_codepoint(b, value->codepoints[0]);
        if (value->codepoints[1]) json_codepoint(b, value->codepoints[1]);
    }
    *consumed = len; return 1;
}
static char *href_json(const MD_CHAR *s, size_t n, int decode) {
    Buffer b = {0}; literal(&b, "\"");
    for (size_t i = 0; i < n; i++) {
        unsigned c = s[i];
        if (decode && c == '\\' && i + 1 < n && punctuation(s[i+1])) c = s[++i];
        else if (decode && c == '&') {
            size_t consumed;
            if (entity(&b, s+i, n-i, &consumed)) { i += consumed - 1; continue; }
        }
        /* CommonMark replaces NULL even inside attributes. Keep all other
         * original UTF16 units; JSON escapes also preserve lone surrogates. */
        json_unit(&b, c ? c : 0xfffd);
    }
    literal(&b, "\"");
    if (b.failed) { free(b.data); return NULL; }
    return b.data;
}
static int collect(int kind, MD_OFFSET beg, MD_OFFSET end, const MD_CHAR *href,
                   MD_SIZE href_size, int mode, void *userdata) {
    Ranges *ranges = userdata;
    if (beg > end) return -3;
    if (ranges->count == ranges->capacity) {
        size_t capacity = ranges->capacity ? ranges->capacity * 2 : 16;
        if (capacity < ranges->capacity || capacity > SIZE_MAX / sizeof(Range)) return -4;
        Range *items = realloc(ranges->items, capacity * sizeof(Range));
        if (!items) return -4;
        ranges->items = items; ranges->capacity = capacity;
    }
    char *encoded = NULL;
    if (kind != 0) {
        if (kind == 2 || mode == 2) href_size = 0;
        encoded = href_json(href, href_size, mode == 1);
        if (!encoded) return -4;
    }
    ranges->items[ranges->count++] = (Range){(unsigned)kind, beg, end, encoded};
    return 0;
}
static int block(MD_BLOCKTYPE type, void *detail, void *userdata) {
    (void)type; (void)detail; (void)userdata; return 0;
}
static int span(MD_SPANTYPE type, void *detail, void *userdata) {
    (void)type; (void)detail; (void)userdata; return 0;
}
static int text(MD_TEXTTYPE type, const MD_CHAR *source, MD_SIZE size, void *userdata) {
    (void)type; (void)source; (void)size; (void)userdata; return 0;
}
static int compare(const void *a, const void *b) {
    const Range *x = a, *y = b;
    if (x->beg != y->beg) return x->beg < y->beg ? -1 : 1;
    if (x->end != y->end) return x->end > y->end ? -1 : 1;
    return x->kind < y->kind ? -1 : x->kind > y->kind;
}
RaftMarkdownContext *raft_markdown_create(int *error) {
    RaftMarkdownContext *context = malloc(sizeof *context);
    if (error) *error = context ? 0 : -4;
    if (context) context->initialized = 1;
    return context;
}
int raft_markdown_parse(RaftMarkdownContext *context, const uint16_t *source, size_t units,
                        char **json, size_t *json_size) {
    if (json) *json = NULL;
    if (json_size) *json_size = 0;
    if (!context || !context->initialized || (!source && units) || !json || !json_size
        || units > UINT_MAX || units > (SIZE_MAX / sizeof(MD_CHAR)) - 1) return -3;
    /* Sentinel is for MD4C's documented NULL-terminated fast-path assumptions;
     * size remains authoritative, so embedded NULL and CRLF keep their offsets. */
    MD_CHAR *input = calloc(units + 1, sizeof *input);
    if (!input) return -4;
    if (units) memcpy(input, source, units * sizeof *input);
    MD_PARSER parser = {0};
    parser.flags = MD_FLAG_PERMISSIVEURLAUTOLINKS | MD_FLAG_PERMISSIVEEMAILAUTOLINKS
        | MD_FLAG_PERMISSIVEWWWAUTOLINKS | MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH
        | MD_FLAG_TASKLISTS | MD_FLAG_NOINDENTEDCODEBLOCKS;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    parser.source_range = collect;
    Ranges ranges = {0};
    int result = md_parse(input, (MD_SIZE)units, &parser, &ranges);
    free(input);
    Buffer output = {0};
    if (result == 0) {
        if (ranges.count > 1) qsort(ranges.items, ranges.count, sizeof(Range), compare);
        /* The JS AST visitor stops at selected links/images: their nested
         * code/images/links must not appear as independent source ranges. */
        unsigned parent_end = 0;
        for (size_t i = 0; i < ranges.count; i++) {
            Range *r = &ranges.items[i];
            if (r->end > units) { result = -3; break; }
            if (r->beg < parent_end && r->end <= parent_end) r->kind = 4;
            else parent_end = r->end;
        }
        literal(&output, "["); int emitted = 0;
        for (int pass = 0; pass < 2 && result == 0; pass++) {
            for (size_t i = 0; i < ranges.count; i++) {
                Range *r = &ranges.items[i];
                if (r->kind == 4 || (pass == 0) != (r->kind == 0)) continue;
                char prefix[100];
                const char *kind[] = {"code", "link", "image", "definition"};
                int n = snprintf(prefix, sizeof prefix, "%s{\"kind\":\"%s\",\"start\":%u,\"end\":%u",
                                 emitted++ ? "," : "", kind[r->kind], r->beg, r->end);
                append(&output, prefix, (size_t)n);
                if (r->kind != 0) { literal(&output, ",\"href\":"); literal(&output, r->href); }
                literal(&output, "}");
            }
        }
        literal(&output, "]");
        if (output.failed) result = -4;
    }
    for (size_t i = 0; i < ranges.count; i++) free(ranges.items[i].href);
    free(ranges.items);
    if (result != 0) { free(output.data); return result == -4 ? -4 : -3; }
    *json = output.data; *json_size = output.size; return 0;
}
void raft_markdown_free(void *allocation) { free(allocation); }
void raft_markdown_destroy(RaftMarkdownContext *context) { free(context); }
