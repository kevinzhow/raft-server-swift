#include "raft_markdown.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>

typedef const void *Value;
typedef void *Handle;
typedef struct {
    Handle library;
    Handle (*global_create)(Handle);
    void (*global_release)(Handle);
    Handle (*string_utf8)(const char *);
    Handle (*string_utf16)(const uint16_t *, size_t);
    void (*string_release)(Handle);
    Value (*evaluate)(Handle, Handle, Handle, Handle, int, Value *);
    Handle (*global_object)(Handle);
    Value (*property)(Handle, Handle, Handle, Value *);
    Handle (*to_object)(Handle, Value, Value *);
    bool (*is_function)(Handle, Handle);
    bool (*is_string)(Handle, Value);
    Value (*make_string)(Handle, Handle);
    Value (*call)(Handle, Handle, Handle, size_t, const Value *, Value *);
    Handle (*to_string)(Handle, Value, Value *);
    size_t (*utf8_capacity)(Handle);
    size_t (*utf8_copy)(Handle, char *, size_t);
    void (*protect)(Handle, Value);
    void (*unprotect)(Handle, Value);
} API;
static API api;
static int available;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

/* JavaScriptCore's public, stable C ABI. No JavaScript IO APIs are installed. */
static void load_runtime(void) {
#ifdef __APPLE__
    const char *name = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore";
#else
    const char *name = "libjavascriptcoregtk-4.1.so.0";
#endif
    api.library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (!api.library) return;
#define LOAD(member, symbol) do { *(void **)(&api.member) = dlsym(api.library, symbol); if (!api.member) return; } while (0)
    LOAD(global_create, "JSGlobalContextCreate");
    LOAD(global_release, "JSGlobalContextRelease");
    LOAD(string_utf8, "JSStringCreateWithUTF8CString");
    LOAD(string_utf16, "JSStringCreateWithCharacters");
    LOAD(string_release, "JSStringRelease");
    LOAD(evaluate, "JSEvaluateScript");
    LOAD(global_object, "JSContextGetGlobalObject");
    LOAD(property, "JSObjectGetProperty");
    LOAD(to_object, "JSValueToObject");
    LOAD(is_function, "JSObjectIsFunction");
    LOAD(is_string, "JSValueIsString");
    LOAD(make_string, "JSValueMakeString");
    LOAD(call, "JSObjectCallAsFunction");
    LOAD(to_string, "JSValueToStringCopy");
    LOAD(utf8_capacity, "JSStringGetMaximumUTF8CStringSize");
    LOAD(utf8_copy, "JSStringGetUTF8CString");
    LOAD(protect, "JSValueProtect");
    LOAD(unprotect, "JSValueUnprotect");
#undef LOAD
    available = 1;
}

struct RaftMarkdownContext { Handle context; Handle function; };

RaftMarkdownContext *raft_markdown_create(const char *bundle, size_t size, int *error) {
    if (error) *error = -1;
    pthread_once(&load_once, load_runtime);
    if (!available) return NULL;
    if (error) *error = -2;
    if (!bundle || size == 0 || memchr(bundle, 0, size)) return NULL;
    if (size == SIZE_MAX) return NULL;
    char *copy = malloc(size + 1);
    RaftMarkdownContext *result = calloc(1, sizeof(*result));
    if (!copy || !result) { free(copy); free(result); if (error) *error = -4; return NULL; }
    memcpy(copy, bundle, size); copy[size] = 0;
    result->context = api.global_create(NULL);
    if (!result->context) { free(copy); free(result); if (error) *error = -4; return NULL; }
    Handle script = api.string_utf8(copy); free(copy);
    if (!script) { raft_markdown_destroy(result); if (error) *error = -4; return NULL; }
    Value exception = NULL;
    api.evaluate(result->context, script, NULL, NULL, 1, &exception);
    api.string_release(script);
    if (exception) { raft_markdown_destroy(result); return NULL; }
    Handle key = api.string_utf8("raftMarkdownSurface");
    if (!key) { raft_markdown_destroy(result); if (error) *error = -4; return NULL; }
    Value function = api.property(result->context, api.global_object(result->context), key, &exception);
    api.string_release(key);
    if (!exception && function) result->function = api.to_object(result->context, function, &exception);
    if (exception || !result->function || !api.is_function(result->context, result->function)) {
        result->function = NULL; raft_markdown_destroy(result); return NULL;
    }
    api.protect(result->context, result->function);
    if (error) *error = 0;
    return result;
}

int raft_markdown_parse(RaftMarkdownContext *parser, const uint16_t *source, size_t units,
                        char **json, size_t *json_size) {
    if (json) *json = NULL;
    if (json_size) *json_size = 0;
    if (!parser || (!source && units) || !json || !json_size) return -3;
    static const uint16_t empty = 0;
    Handle text = api.string_utf16(source ? source : &empty, units);
    if (!text) return -4;
    Value argument = api.make_string(parser->context, text), exception = NULL;
    Value value = api.call(parser->context, parser->function, NULL, 1, &argument, &exception);
    api.string_release(text);
    if (exception || !value || !api.is_string(parser->context, value)) return -3;
    Handle rendered = api.to_string(parser->context, value, &exception);
    if (exception || !rendered) return -3;
    size_t capacity = api.utf8_capacity(rendered);
    char *buffer = malloc(capacity);
    if (!buffer) { api.string_release(rendered); return -4; }
    size_t written = api.utf8_copy(rendered, buffer, capacity);
    api.string_release(rendered);
    if (written == 0) { free(buffer); return -3; }
    *json = buffer; *json_size = written - 1;
    return 0;
}

void raft_markdown_free(void *allocation) { free(allocation); }
void raft_markdown_destroy(RaftMarkdownContext *context) {
    if (!context) return;
    if (context->function) api.unprotect(context->context, context->function);
    if (context->context) api.global_release(context->context);
    free(context);
}
