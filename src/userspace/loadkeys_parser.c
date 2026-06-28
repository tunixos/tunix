#include "loadkeys_parser.h"

struct symbol_name {
    const char *name;
    uint32_t value;
};

static const struct symbol_name symbol_names[] = {
    {"nul", 0}, {"space", ' '}, {"exclam", '!'}, {"quotedbl", '"'},
    {"numbersign", '#'}, {"dollar", '$'}, {"percent", '%'},
    {"ampersand", '&'}, {"apostrophe", '\''}, {"parenleft", '('},
    {"parenright", ')'}, {"asterisk", '*'}, {"plus", '+'},
    {"comma", ','}, {"minus", '-'}, {"period", '.'}, {"slash", '/'},
    {"zero", '0'}, {"one", '1'}, {"two", '2'}, {"three", '3'},
    {"four", '4'}, {"five", '5'}, {"six", '6'}, {"seven", '7'},
    {"eight", '8'}, {"nine", '9'}, {"colon", ':'}, {"semicolon", ';'},
    {"less", '<'}, {"equal", '='}, {"greater", '>'}, {"question", '?'},
    {"at", '@'}, {"bracketleft", '['}, {"backslash", '\\'},
    {"bracketright", ']'}, {"asciicircum", '^'}, {"underscore", '_'},
    {"grave", '`'}, {"braceleft", '{'}, {"bar", '|'},
    {"braceright", '}'}, {"asciitilde", '~'},
    {"Escape", 0x1b}, {"Delete", 0x7f}, {"BackSpace", 0x7f},
    {"Tab", '\t'}, {"Return", '\r'},
    {"sterling", 0x00a3}, {"onehalf", 0x00bd}, {"euro", 0x20ac},
    {"acute", 0x00b4}, {"diaeresis", 0x00a8}, {"eacute", 0x00e9},
    {"acircumflex", 0x00e2}, {"Acircumflex", 0x00c2},
    {"ccedilla", 0x00e7}, {"Ccedilla", 0x00c7},
    {"gbreve", 0x011f}, {"Gbreve", 0x011e},
    {"icircumflex", 0x00ee}, {"Icircumflex", 0x00ce},
    {"dotlessi", 0x0131}, {"Idotabove", 0x0130},
    {"ocircumflex", 0x00f4}, {"Ocircumflex", 0x00d4},
    {"odiaeresis", 0x00f6}, {"Odiaeresis", 0x00d6},
    {"scedilla", 0x015f}, {"Scedilla", 0x015e},
    {"ucircumflex", 0x00fb}, {"Ucircumflex", 0x00db},
    {"udiaeresis", 0x00fc}, {"Udiaeresis", 0x00dc},
    {"VoidSymbol", TUNIX_KEYSYM_NONE}, {"NoSymbol", TUNIX_KEYSYM_NONE},
    {"Shift", TUNIX_KEYSYM_NONE}, {"Control", TUNIX_KEYSYM_NONE},
    {"Alt", TUNIX_KEYSYM_NONE}, {"AltGr", TUNIX_KEYSYM_NONE},
    {"Caps_Lock", TUNIX_KEYSYM_NONE}, {"Backtab", TUNIX_KEYSYM_NONE}
};

static int string_equal(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static int starts_with(const char *text, const char *prefix) {
    while (*prefix) if (*text++ != *prefix++) return 0;
    return 1;
}

static void copy_text(char *destination, size_t capacity, const char *source) {
    size_t at = 0;
    if (!capacity) return;
    while (at + 1U < capacity && source[at]) {
        destination[at] = source[at];
        at++;
    }
    destination[at] = 0;
}

static void set_error(struct lk_error *error, unsigned line,
                      const char *token, const char *message) {
    if (!error) return;
    error->line = line;
    copy_text(error->token, sizeof(error->token), token ? token : "");
    error->message = message;
}

static int parse_unsigned(const char *text, unsigned base, uint32_t *value) {
    uint32_t result = 0;
    unsigned digits = 0;
    while (*text) {
        unsigned digit;
        if (*text >= '0' && *text <= '9') digit = (unsigned)(*text - '0');
        else if (*text >= 'a' && *text <= 'f') digit = (unsigned)(*text - 'a' + 10);
        else if (*text >= 'A' && *text <= 'F') digit = (unsigned)(*text - 'A' + 10);
        else return -1;
        if (digit >= base || result > (0xffffffffU - digit) / base) return -1;
        result = result * base + digit;
        digits++;
        text++;
    }
    if (!digits) return -1;
    *value = result;
    return 0;
}

static int utf8_decode_one(const char *text, uint32_t *value) {
    const unsigned char *bytes = (const unsigned char *)text;
    if (!bytes[0]) return -1;
    if (bytes[0] < 0x80U) {
        if (bytes[1]) return -1;
        *value = bytes[0];
        return 0;
    }
    unsigned count;
    uint32_t result;
    if ((bytes[0] & 0xe0U) == 0xc0U) { count = 2; result = bytes[0] & 0x1fU; }
    else if ((bytes[0] & 0xf0U) == 0xe0U) { count = 3; result = bytes[0] & 0x0fU; }
    else if ((bytes[0] & 0xf8U) == 0xf0U) { count = 4; result = bytes[0] & 0x07U; }
    else return -1;
    for (unsigned i = 1; i < count; i++) {
        if ((bytes[i] & 0xc0U) != 0x80U) return -1;
        result = (result << 6) | (bytes[i] & 0x3fU);
    }
    if (bytes[count]) return -1;
    if ((count == 2 && result < 0x80U) || (count == 3 && result < 0x800U) ||
        (count == 4 && result < 0x10000U) || result > 0x10ffffU ||
        (result >= 0xd800U && result <= 0xdfffU)) return -1;
    *value = result;
    return 0;
}

static uint32_t control_value(uint32_t value) {
    if (value == ' ') return 0;
    if (value >= 'a' && value <= 'z') return value - 'a' + 1U;
    if (value >= 'A' && value <= 'Z') return value - 'A' + 1U;
    if (value >= '@' && value <= '_') return value & 0x1fU;
    if (value == '?') return 0x7fU;
    return value;
}

static int parse_symbol(const char *token, uint32_t *value, int *letter) {
    *letter = 0;
    while (*token == '+') { *letter = 1; token++; }
    int control = 0;
    if (starts_with(token, "Meta_")) token += 5;
    if (starts_with(token, "Control_")) { control = 1; token += 8; }
    if (starts_with(token, "U+") || starts_with(token, "u+")) {
        if (parse_unsigned(token + 2, 16, value) != 0) return -1;
    } else if (starts_with(token, "0x") || starts_with(token, "0X")) {
        if (parse_unsigned(token + 2, 16, value) != 0) return -1;
    } else if (token[0] == '\'' && token[1] && token[2] == '\'' && token[3] == 0) {
        *value = (uint8_t)token[1];
    } else {
        for (size_t i = 0; i < sizeof(symbol_names) / sizeof(symbol_names[0]); i++) {
            if (string_equal(token, symbol_names[i].name)) {
                *value = symbol_names[i].value;
                if (control && *value != TUNIX_KEYSYM_NONE) *value = control_value(*value);
                return 0;
            }
        }
        if (utf8_decode_one(token, value) != 0) return -1;
        if ((*value >= 'a' && *value <= 'z') || (*value >= 'A' && *value <= 'Z'))
            *letter = 1;
    }
    if (*value > 0x10ffffU && *value != TUNIX_KEYSYM_NONE) return -1;
    if (control && *value != TUNIX_KEYSYM_NONE) *value = control_value(*value);
    return 0;
}

void lk_keymap_reset(struct tunix_keymap *map, const char *name) {
    unsigned char *bytes = (unsigned char *)map;
    for (size_t i = 0; i < sizeof(*map); i++) bytes[i] = 0;
    map->version = TUNIX_KEYMAP_ABI_VERSION;
    copy_text(map->name, sizeof(map->name), name ? name : "custom");
    for (unsigned level = 0; level < TUNIX_KEYMAP_LEVELS; level++)
        for (unsigned code = 0; code < TUNIX_KEYMAP_KEYCODES; code++)
            map->symbols[level][code] = TUNIX_KEYSYM_NONE;
}

static void mark_letter(struct tunix_keymap *map, unsigned keycode) {
    map->letter_bitmap[keycode >> 3] |= (uint8_t)(1U << (keycode & 7U));
}

static int tokenize(char *line, char *tokens[], unsigned capacity) {
    unsigned count = 0;
    char *at = line;
    while (*at) {
        while (*at == ' ' || *at == '\t') at++;
        if (!*at || *at == '#') break;
        if (count == capacity) return -1;
        if (*at == '"') {
            at++;
            tokens[count++] = at;
            while (*at && *at != '"') at++;
            if (*at) *at++ = 0;
            continue;
        }
        tokens[count++] = at;
        while (*at && *at != ' ' && *at != '\t' && *at != '#') at++;
        if (*at == '#') { *at = 0; break; }
        if (*at) *at++ = 0;
    }
    return (int)count;
}

static int parse_line(struct tunix_keymap *map, char *line, unsigned line_number,
                      lk_include_callback include_callback, void *context,
                      struct lk_error *error) {
    char *tokens[24];
    int count = tokenize(line, tokens, 24);
    if (count < 0) { set_error(error, line_number, "", "too many tokens"); return -1; }
    if (count == 0) return 0;
    if (string_equal(tokens[0], "include")) {
        if (count < 2 || !include_callback) {
            set_error(error, line_number, tokens[0], "include cannot be resolved");
            return -1;
        }
        return include_callback(context, tokens[1], map, error);
    }
    if (string_equal(tokens[0], "charset") || string_equal(tokens[0], "keymaps") ||
        string_equal(tokens[0], "strings") || string_equal(tokens[0], "compose") ||
        string_equal(tokens[0], "alt_is_meta")) return 0;

    unsigned level = 0;
    unsigned at = 0;
    int explicit_level = 0;
    int ignore_alt = 0;
    while (at < (unsigned)count && !string_equal(tokens[at], "keycode")) {
        explicit_level = 1;
        if (string_equal(tokens[at], "plain")) level = 0;
        else if (string_equal(tokens[at], "shift")) level |= TUNIX_KEYMAP_LEVEL_SHIFT;
        else if (string_equal(tokens[at], "altgr")) level |= TUNIX_KEYMAP_LEVEL_ALTGR;
        else if (string_equal(tokens[at], "control") || string_equal(tokens[at], "ctrl"))
            level |= TUNIX_KEYMAP_LEVEL_CTRL;
        else if (string_equal(tokens[at], "alt")) ignore_alt = 1;
        else { set_error(error, line_number, tokens[at], "unsupported directive"); return -1; }
        at++;
    }
    if (at >= (unsigned)count || at + 3U >= (unsigned)count ||
        !string_equal(tokens[at + 2U], "=")) {
        set_error(error, line_number, tokens[0], "expected: [modifiers] keycode N = symbol");
        return -1;
    }
    uint32_t keycode;
    if (parse_unsigned(tokens[at + 1U], 10, &keycode) != 0 ||
        keycode >= TUNIX_KEYMAP_KEYCODES) {
        set_error(error, line_number, tokens[at + 1U], "keycode out of range");
        return -1;
    }
    if (ignore_alt) return 0;
    unsigned symbol_at = at + 3U;
    unsigned destination_level = explicit_level ? level : 0U;
    for (; symbol_at < (unsigned)count; symbol_at++) {
        if (destination_level >= TUNIX_KEYMAP_LEVELS) break;
        uint32_t value;
        int letter;
        if (parse_symbol(tokens[symbol_at], &value, &letter) != 0) {
            set_error(error, line_number, tokens[symbol_at], "unknown keysym");
            return -1;
        }
        map->symbols[destination_level][keycode] = value;
        if (letter) mark_letter(map, keycode);
        if (explicit_level) break;
        destination_level++;
    }
    return 0;
}

int lk_parse_buffer(struct tunix_keymap *map, const char *buffer, size_t size,
                    lk_include_callback include_callback, void *context,
                    struct lk_error *error) {
    char line[512];
    size_t offset = 0;
    unsigned line_number = 1;
    while (offset < size) {
        size_t length = 0;
        while (offset < size && buffer[offset] != '\n' && buffer[offset] != '\r') {
            if (length + 1U >= sizeof(line)) {
                set_error(error, line_number, "", "line too long");
                return -1;
            }
            line[length++] = buffer[offset++];
        }
        line[length] = 0;
        while (offset < size && (buffer[offset] == '\n' || buffer[offset] == '\r')) offset++;
        if (parse_line(map, line, line_number, include_callback, context, error) != 0) {
            if (error && error->line == 0) error->line = line_number;
            return -1;
        }
        line_number++;
    }
    return 0;
}
