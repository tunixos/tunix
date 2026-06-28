#include "tunix_libc.h"
#include "loadkeys_parser.h"

#define FILE_BUFFER_SIZE 32768U
#define INCLUDE_DEPTH_MAX 4U
#define PATH_BUFFER_SIZE 256U

static char file_buffers[INCLUDE_DEPTH_MAX][FILE_BUFFER_SIZE];
static char last_path[PATH_BUFFER_SIZE];
static int verbose_mode;

static void write_text(int fd, const char *text) {
    if (text) (void)t_write(fd, text, t_strlen(text));
}

static void write_unsigned(int fd, unsigned value) {
    char buffer[16];
    unsigned length = 0;
    do {
        buffer[length++] = (char)('0' + value % 10U);
        value /= 10U;
    } while (value);
    while (length) (void)t_write(fd, &buffer[--length], 1);
}

static int text_equal(const char *a, const char *b) {
    return t_strcmp(a, b) == 0;
}

static int has_slash(const char *text) {
    return t_strchr(text, '/') != 0;
}

static int ends_with(const char *text, const char *suffix) {
    size_t text_length = t_strlen(text);
    size_t suffix_length = t_strlen(suffix);
    if (suffix_length > text_length) return 0;
    return t_strcmp(text + text_length - suffix_length, suffix) == 0;
}

static int path_join(char *output, size_t capacity,
                     const char *directory, const char *name,
                     int append_map) {
    size_t used = 0;
    for (size_t i = 0; directory && directory[i]; i++) {
        if (used + 1U >= capacity) return -1;
        output[used++] = directory[i];
    }
    if (used && output[used - 1U] != '/') {
        if (used + 1U >= capacity) return -1;
        output[used++] = '/';
    }
    for (size_t i = 0; name[i]; i++) {
        if (used + 1U >= capacity) return -1;
        output[used++] = name[i];
    }
    if (append_map) {
        const char suffix[] = ".map";
        for (size_t i = 0; suffix[i]; i++) {
            if (used + 1U >= capacity) return -1;
            output[used++] = suffix[i];
        }
    }
    output[used] = 0;
    return 0;
}

static void copy_path(char *destination, size_t capacity, const char *source) {
    size_t i = 0;
    if (!capacity) return;
    while (i + 1U < capacity && source[i]) {
        destination[i] = source[i];
        i++;
    }
    destination[i] = 0;
}

static void directory_of(const char *path, char *directory, size_t capacity) {
    size_t last = 0;
    for (size_t i = 0; path[i]; i++) if (path[i] == '/') last = i;
    if (!last) {
        copy_path(directory, capacity, ".");
        return;
    }
    if (last >= capacity) last = capacity - 1U;
    for (size_t i = 0; i < last; i++) directory[i] = path[i];
    directory[last] = 0;
}

struct include_context {
    char directory[PATH_BUFFER_SIZE];
    unsigned depth;
};

static int parse_file_path(const char *path, struct tunix_keymap *map,
                           unsigned depth, struct lk_error *error);

static int try_parse_candidate(const char *path, struct tunix_keymap *map,
                               unsigned depth, struct lk_error *error) {
    struct tunix_keymap backup = *map;
    if (parse_file_path(path, map, depth, error) == 0) return 0;
    *map = backup;
    return -1;
}

static int try_named_file(const char *name, const char *relative_directory,
                          struct tunix_keymap *map, unsigned depth,
                          struct lk_error *error) {
    char path[PATH_BUFFER_SIZE];
    const char *directories[] = {
        relative_directory,
        "/usr/share/keymaps",
        "/usr/share/kbd/keymaps",
        0
    };
    if (name[0] == '/') {
        if (try_parse_candidate(name, map, depth, error) == 0) return 0;
        if (!ends_with(name, ".map") && path_join(path, sizeof(path), "", name, 1) == 0 &&
            try_parse_candidate(path, map, depth, error) == 0) return 0;
        return -1;
    }
    if (has_slash(name)) {
        if (path_join(path, sizeof(path), relative_directory, name, 0) == 0 &&
            try_parse_candidate(path, map, depth, error) == 0) return 0;
        if (!ends_with(name, ".map") &&
            path_join(path, sizeof(path), relative_directory, name, 1) == 0 &&
            try_parse_candidate(path, map, depth, error) == 0) return 0;
        return -1;
    }
    for (unsigned i = 0; directories[i]; i++) {
        if (!directories[i]) continue;
        if (path_join(path, sizeof(path), directories[i], name, 0) == 0 &&
            try_parse_candidate(path, map, depth, error) == 0) return 0;
        if (!ends_with(name, ".map") &&
            path_join(path, sizeof(path), directories[i], name, 1) == 0 &&
            try_parse_candidate(path, map, depth, error) == 0) return 0;
    }
    return -1;
}

static int include_file(void *opaque, const char *name,
                        struct tunix_keymap *map, struct lk_error *error) {
    struct include_context *context = (struct include_context *)opaque;
    if (context->depth + 1U >= INCLUDE_DEPTH_MAX) {
        if (error) { error->line = 0; error->message = "include nesting too deep"; }
        return -1;
    }
    return try_named_file(name, context->directory, map, context->depth + 1U, error);
}

static int parse_file_path(const char *path, struct tunix_keymap *map,
                           unsigned depth, struct lk_error *error) {
    if (depth >= INCLUDE_DEPTH_MAX) return -1;
    int fd = t_open(path, T_O_RDONLY, 0);
    if (fd < 0) return -1;
    size_t used = 0;
    while (used < FILE_BUFFER_SIZE) {
        long amount = t_read(fd, file_buffers[depth] + used, FILE_BUFFER_SIZE - used);
        if (amount < 0) { t_close(fd); return -1; }
        if (amount == 0) break;
        used += (size_t)amount;
    }
    t_close(fd);
    if (used == FILE_BUFFER_SIZE) {
        if (error) { error->line = 0; error->message = "keymap file is too large"; }
        return -1;
    }
    struct include_context context;
    directory_of(path, context.directory, sizeof(context.directory));
    context.depth = depth;
    copy_path(last_path, sizeof(last_path), path);
    if (verbose_mode) {
        write_text(1, "loadkeys: reading ");
        write_text(1, path);
        write_text(1, "\n");
    }
    return lk_parse_buffer(map, file_buffers[depth], used,
                           include_file, &context, error);
}

static void map_name_from_argument(struct tunix_keymap *map, const char *argument) {
    const char *name = t_basename(argument);
    size_t length = t_strlen(name);
    if (length > 4U && t_strcmp(name + length - 4U, ".map") == 0) length -= 4U;
    if (length >= sizeof(map->name)) length = sizeof(map->name) - 1U;
    for (size_t i = 0; i < length; i++) map->name[i] = name[i];
    map->name[length] = 0;
}

static int maps_equal(const struct tunix_keymap *a, const struct tunix_keymap *b) {
    const unsigned char *left = (const unsigned char *)a;
    const unsigned char *right = (const unsigned char *)b;
    for (size_t i = 0; i < sizeof(*a); i++) if (left[i] != right[i]) return 0;
    return 1;
}

static int self_test(int console_fd) {
    struct tunix_keymap original;
    struct tunix_keymap test;
    struct tunix_keymap actual;
    if (t_ioctl(console_fd, TUNIX_KDGKBMAP, &original) != 0) return -1;
    test = original;
    copy_path(test.name, sizeof(test.name), "self-test");
    test.symbols[0][2] = 'x';
    if (t_ioctl(console_fd, TUNIX_KDSKBMAP, &test) != 0) return -1;
    if (t_ioctl(console_fd, TUNIX_KDGKBMAP, &actual) != 0 || !maps_equal(&test, &actual)) {
        (void)t_ioctl(console_fd, TUNIX_KDSKBMAP, &original);
        return -1;
    }
    if (t_ioctl(console_fd, TUNIX_KDSKBMAP, &original) != 0) return -1;
    return 0;
}

static void usage(void) {
    t_puts("Usage: loadkeys [options] MAP\n"
           "  -d, --default       load the us map\n"
           "  -q, --quiet         suppress success output\n"
           "  -v, --verbose       show files being parsed\n"
           "  -C, --console DEV   use a different console device\n"
           "  -l, --list          list bundled keymaps\n"
           "      --show-current  print the active keymap name\n"
           "      --self-test     verify the kernel keymap ioctl\n"
           "      --help          show this help\n"
           "      --version       show version information\n");
}

int main(int argc, char **argv, char **envp) {
    (void)envp;
    const char *map_argument = 0;
    const char *console_path = "/dev/console";
    int quiet = 0;
    int show_current = 0;
    int run_self_test = 0;

    for (int i = 1; i < argc; i++) {
        const char *argument = argv[i];
        if (text_equal(argument, "-d") || text_equal(argument, "--default")) map_argument = "us";
        else if (text_equal(argument, "-q") || text_equal(argument, "--quiet")) quiet = 1;
        else if (text_equal(argument, "-v") || text_equal(argument, "--verbose")) verbose_mode++;
        else if (text_equal(argument, "-l") || text_equal(argument, "--list")) {
            t_puts("us\ntrq\n");
            return 0;
        } else if (text_equal(argument, "--show-current")) show_current = 1;
        else if (text_equal(argument, "--self-test")) run_self_test = 1;
        else if (text_equal(argument, "--help") || text_equal(argument, "-h")) { usage(); return 0; }
        else if (text_equal(argument, "--version") || text_equal(argument, "-V")) {
            t_puts("loadkeys (Tunix kbd compatibility) 1.0\n");
            return 0;
        } else if (text_equal(argument, "-C") || text_equal(argument, "--console")) {
            if (++i >= argc) { t_puterr("loadkeys: missing console path\n"); return 2; }
            console_path = argv[i];
        } else if (argument[0] == '-') {
            t_puterr("loadkeys: unknown option: "); t_puterr(argument); t_puterr("\n");
            return 2;
        } else if (!map_argument) map_argument = argument;
        else { t_puterr("loadkeys: only one keymap may be loaded\n"); return 2; }
    }

    int console_fd = t_open(console_path, T_O_RDWR | T_O_NOCTTY, 0);
    if (console_fd < 0) {
        t_puterr("loadkeys: cannot open console: "); t_puterr(console_path); t_puterr("\n");
        return 1;
    }
    if (run_self_test) {
        int result = self_test(console_fd);
        t_close(console_fd);
        if (result != 0) { t_puterr("loadkeys: self-test failed\n"); return 1; }
        if (!quiet) t_puts("loadkeys: self-test passed\n");
        return 0;
    }
    if (show_current) {
        struct tunix_keymap current;
        if (t_ioctl(console_fd, TUNIX_KDGKBMAP, &current) != 0) {
            t_puterr("loadkeys: cannot query active keymap\n"); t_close(console_fd); return 1;
        }
        t_puts(current.name); t_puts("\n");
        t_close(console_fd);
        return 0;
    }
    if (!map_argument) {
        usage();
        t_close(console_fd);
        return 2;
    }

    struct tunix_keymap map;
    struct lk_error error = {0, "", 0};
    lk_keymap_reset(&map, "custom");
    last_path[0] = 0;
    if (try_named_file(map_argument, ".", &map, 0, &error) != 0) {
        t_puterr("loadkeys: failed to parse ");
        t_puterr(last_path[0] ? last_path : map_argument);
        if (error.line) { t_puterr(":"); write_unsigned(2, error.line); }
        if (error.token[0]) { t_puterr(": "); t_puterr(error.token); }
        if (error.message) { t_puterr(": "); t_puterr(error.message); }
        t_puterr("\n");
        t_close(console_fd);
        return 1;
    }
    map_name_from_argument(&map, map_argument);
    if (t_ioctl(console_fd, TUNIX_KDSKBMAP, &map) != 0) {
        t_puterr("loadkeys: kernel rejected keymap\n");
        t_close(console_fd);
        return 1;
    }
    t_close(console_fd);
    if (!quiet) { t_puts("Loading "); t_puts(map.name); t_puts(" keymap: done\n"); }
    return 0;
}
