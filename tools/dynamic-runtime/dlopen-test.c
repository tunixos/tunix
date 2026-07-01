#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/usr/lib/libtunix_dynamic.so.1";
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "dlopen-test: %s\n", dlerror());
        return 1;
    }

    dlerror();
    int (*answer)(void) = (int (*)(void))dlsym(handle, "tunix_dynamic_answer");
    const char *error = dlerror();
    if (error || !answer) {
        fprintf(stderr, "dlopen-test: %s\n", error ? error : "symbol missing");
        dlclose(handle);
        return 2;
    }

    int value = answer();
    printf("dlopen-test: answer=%d\n", value);
    if (dlclose(handle) != 0) {
        fprintf(stderr, "dlopen-test: dlclose failed: %s\n", dlerror());
        return 3;
    }
    return value == 42 ? 0 : 4;
}
