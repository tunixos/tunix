/*
 * xkb-test -- prove libxkbcommon can actually compile a keymap.
 *
 * Weston turns evdev keycodes into keysyms through this library, so "it links"
 * is not the interesting property; "it parses a keymap and resolves a key" is.
 *
 * Two paths, and they have different requirements:
 *
 *   from a string  the keymap text is supplied inline, so this exercises the
 *                  parser and the keysym tables with no data files at all
 *   from names     the usual evdev/pc105/us lookup, which reads the
 *                  xkeyboard-config database under XKB_CONFIG_ROOT
 *
 * Only the first is a hard failure. The second is reported rather than
 * enforced, because the database is a separate project that this port does not
 * build -- and knowing whether it is missing is exactly the point.
 */

#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

/*
 * A minimal but complete keymap. The four sections are all mandatory; xkbcommon
 * rejects a keymap missing any of them. <AD01> is the key in the Q position on
 * a US layout, which is what the lookup below checks for.
 */
static const char KEYMAP[] =
    "xkb_keymap {\n"
    "  xkb_keycodes { <AD01> = 24; };\n"
    "  xkb_types { type \"ONE_LEVEL\" {\n"
    "    modifiers = none;\n"
    "    level_name[1] = \"Any\";\n"
    "  }; };\n"
    "  xkb_compat { };\n"
    "  xkb_symbols {\n"
    "    key <AD01> { type = \"ONE_LEVEL\", [ q ] };\n"
    "  };\n"
    "};\n";

static int failures;

static void check(int condition, const char *what) {
    if (condition) {
        printf("xkb-test: ok   %s\n", what);
    } else {
        printf("xkb-test: FAIL %s\n", what);
        failures++;
    }
}

int main(void) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    check(context != NULL, "create an xkb context");
    if (!context) return 1;

    struct xkb_keymap *keymap = xkb_keymap_new_from_string(
        context, KEYMAP, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    check(keymap != NULL, "compile a keymap from a string");

    if (keymap) {
        struct xkb_state *state = xkb_state_new(keymap);
        check(state != NULL, "create keyboard state");
        if (state) {
            /* Keycode 24 is <AD01>, which the keymap above maps to 'q'. */
            xkb_keysym_t sym = xkb_state_key_get_one_sym(state, 24);
            char name[64] = {0};
            xkb_keysym_get_name(sym, name, sizeof(name));
            check(sym == XKB_KEY_q, "resolve keycode 24 to the keysym q");
            printf("xkb-test: keycode 24 -> %s\n", name);
            xkb_state_unref(state);
        }
        xkb_keymap_unref(keymap);
    }

    /* The data-driven path. Reported, not enforced: see the header comment. */
    struct xkb_rule_names names = {
        .rules = NULL, .model = NULL, .layout = "us",
        .variant = NULL, .options = NULL,
    };
    struct xkb_keymap *from_names = xkb_keymap_new_from_names(
        context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (from_names) {
        printf("xkb-test: xkeyboard-config data present (default layout compiled)\n");
        xkb_keymap_unref(from_names);
    } else {
        printf("xkb-test: xkeyboard-config data MISSING "
               "(keymap-from-names unavailable; weston will need it)\n");
    }

    xkb_context_unref(context);
    if (failures) {
        printf("xkb-test: FAIL (%d)\n", failures);
        return 1;
    }
    printf("xkb-test: PASS\n");
    return 0;
}
