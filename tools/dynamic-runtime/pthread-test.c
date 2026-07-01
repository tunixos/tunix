#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static _Thread_local int worker_tls = 7;

static void *worker(void *argument) {
    worker_tls += (int)(intptr_t)argument;
    return (void *)(intptr_t)worker_tls;
}

int main(void) {
    pthread_t thread;
    void *result = 0;
    int status = pthread_create(&thread, 0, worker, (void *)(intptr_t)35);
    if (status != 0) {
        fprintf(stderr, "pthread-test: pthread_create=%d\n", status);
        return 1;
    }
    status = pthread_join(thread, &result);
    if (status != 0) {
        fprintf(stderr, "pthread-test: pthread_join=%d\n", status);
        return 2;
    }
    printf("pthread-test: worker_tls=%ld main_tls=%d\n",
           (long)(intptr_t)result, worker_tls);
    return (intptr_t)result == 42 && worker_tls == 7 ? 0 : 3;
}
