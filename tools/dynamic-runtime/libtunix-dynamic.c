#include <stddef.h>

int tunix_dynamic_answer(void) {
    return 42;
}

const char *tunix_dynamic_runtime(void) {
    return "shared-musl";
}
