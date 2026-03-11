#ifndef CODEX_SWIFT_BRIDGE_H
#define CODEX_SWIFT_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CodexSwiftBridge CodexSwiftBridge;

CodexSwiftBridge *codex_swift_bridge_create(const char *config_json, char **error_out);
bool codex_swift_bridge_send(
    CodexSwiftBridge *bridge,
    const char *payload_json,
    char **error_out
);
char *codex_swift_bridge_recv(
    CodexSwiftBridge *bridge,
    uint32_t timeout_millis,
    char **error_out
);
void codex_swift_bridge_destroy(CodexSwiftBridge *bridge);
void codex_swift_bridge_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
