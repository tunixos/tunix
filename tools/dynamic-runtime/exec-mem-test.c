/*
 * exec-mem-test: can a process write code and then run it?
 *
 * This is the precondition for JavaScriptCore's JIT, and it is worth asking
 * separately because the failure mode inside a browser is unreadable -- a JIT
 * that cannot get executable memory crashes somewhere deep in a compile thread,
 * a long way from the mmap that actually said no.
 *
 * Two shapes are checked, because JSC uses both. Straight PROT_EXEC on fresh
 * anonymous memory, and the W^X flip: map writable, emit the code, mprotect it
 * to read-execute, then call it. The second is the one that depends on the
 * kernel clearing the NX bit on a page it had already mapped as no-execute.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

/* mov eax, EXPECTED_RESULT ; ret -- the smallest function worth calling. */
#define EXPECTED_RESULT 0x2A
static const unsigned char RETURN_CONSTANT[] = {
    0xB8, EXPECTED_RESULT, 0x00, 0x00, 0x00,
    0xC3
};

typedef int (*code_fn)(void);

static int run_from(void *page, const char *what) {
    memcpy(page, RETURN_CONSTANT, sizeof RETURN_CONSTANT);
    code_fn call = (code_fn)page;
    int result = call();
    if (result != EXPECTED_RESULT) {
        fprintf(stderr, "exec-mem-test: %s returned %d, expected %d\n",
                what, result, EXPECTED_RESULT);
        return -1;
    }
    printf("exec-mem-test: %s ok\n", what);
    return 0;
}

int main(void) {
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) page_size = 4096;

    void *rwx = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx == MAP_FAILED) {
        perror("exec-mem-test: mmap PROT_EXEC");
        return 1;
    }
    if (run_from(rwx, "write-then-run in one mapping") != 0) return 1;
    munmap(rwx, (size_t)page_size);

    void *flip = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (flip == MAP_FAILED) {
        perror("exec-mem-test: mmap PROT_WRITE");
        return 1;
    }
    memcpy(flip, RETURN_CONSTANT, sizeof RETURN_CONSTANT);
    if (mprotect(flip, (size_t)page_size, PROT_READ | PROT_EXEC) != 0) {
        perror("exec-mem-test: mprotect PROT_EXEC");
        return 1;
    }
    code_fn call = (code_fn)flip;
    if (call() != EXPECTED_RESULT) {
        fprintf(stderr, "exec-mem-test: the W^X flip returned the wrong value\n");
        return 1;
    }
    printf("exec-mem-test: mprotect to read-execute ok\n");
    munmap(flip, (size_t)page_size);

    printf("exec-mem-test: executable memory works\n");
    return 0;
}
