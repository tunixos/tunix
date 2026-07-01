#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static _Thread_local int tls_probe = 40;

int main(int argc, char **argv) {
    char *memory = malloc(32);
    if (!memory) {
        fputs("dynamic-hello: malloc failed\n", stderr);
        return 1;
    }
    tls_probe += 2;
    snprintf(memory, 32, "%d", tls_probe);
    printf("dynamic-hello: pid=%ld argc=%d tls=%s argv0=%s\n",
           (long)getpid(), argc, memory,
           argc > 0 && argv[0] ? argv[0] : "(null)");
    free(memory);
    return tls_probe == 42 ? 0 : 2;
}
