#ifndef TUNIX_LOADKEYS_PARSER_H
#define TUNIX_LOADKEYS_PARSER_H

#include <stddef.h>
#include <stdint.h>
#include <tunix/keymap.h>

#define LK_TOKEN_MAX 64U

struct lk_error {
    unsigned line;
    char token[LK_TOKEN_MAX];
    const char *message;
};

typedef int (*lk_include_callback)(void *context, const char *name,
                                  struct tunix_keymap *map,
                                  struct lk_error *error);

void lk_keymap_reset(struct tunix_keymap *map, const char *name);
int lk_parse_buffer(struct tunix_keymap *map, const char *buffer, size_t size,
                    lk_include_callback include_callback, void *context,
                    struct lk_error *error);

#endif
