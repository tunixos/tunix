/*
 * wayland-roundtrip-test -- a real Wayland server and client, in one process
 * tree, talking over a real unix socket.
 *
 * The synthetic shm-test proved the kernel primitives in isolation. This proves
 * they compose the way libwayland actually uses them, which is the thing that
 * has to be true before Weston is worth attempting:
 *
 *   - wl_display_add_socket_auto()  binds a listening unix socket
 *   - wl_display_connect()          connects and completes the handshake
 *   - wl_display_roundtrip()        marshals a request and dispatches the reply,
 *                                   which is libffi doing its job
 *   - wl_shm_create_pool(fd)        sends a memfd over SCM_RIGHTS, and the
 *                                   *server* mmaps it
 *
 * The last one is the interesting assertion. libwayland's shm implementation
 * mmaps the descriptor it receives and raises a protocol error if that fails,
 * so a pool that is created without an error is proof the server really mapped
 * the client's memory. wl_display_get_error() is what catches it, because a
 * protocol error arrives asynchronously rather than as a failed call.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-server.h>

#define BUFFER_WIDTH 64
#define BUFFER_HEIGHT 64
#define BUFFER_STRIDE (BUFFER_WIDTH * 4)
#define BUFFER_BYTES (BUFFER_STRIDE * BUFFER_HEIGHT)

/* ---------------------------------------------------------------- client -- */

struct client_state {
    struct wl_shm *shm;
    int formats_seen;
};

static void handle_shm_format(void *data, struct wl_shm *shm, uint32_t format) {
    (void)shm;
    (void)format;
    ((struct client_state *)data)->formats_seen++;
}

static const struct wl_shm_listener shm_listener = { handle_shm_format };

static void handle_global(void *data, struct wl_registry *registry,
                          uint32_t name, const char *interface,
                          uint32_t version) {
    (void)version;
    struct client_state *state = data;
    if (strcmp(interface, "wl_shm") == 0) {
        state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
        wl_shm_add_listener(state->shm, &shm_listener, state);
    }
}

static void handle_global_remove(void *data, struct wl_registry *registry,
                                 uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    handle_global, handle_global_remove
};

static int make_memfd(size_t size) {
    int fd = (int)syscall(SYS_memfd_create, "wl-roundtrip", 0);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int run_client(const char *socket_name) {
    struct wl_display *display = wl_display_connect(socket_name);
    if (!display) {
        fprintf(stderr, "client: cannot connect to %s (errno=%d)\n",
                socket_name, errno);
        return 2;
    }

    struct client_state state;
    memset(&state, 0, sizeof(state));

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &state);

    /* First roundtrip delivers the globals, second delivers the shm formats
       that binding wl_shm triggers. */
    if (wl_display_roundtrip(display) < 0) return 3;
    if (!state.shm) {
        fprintf(stderr, "client: the server advertised no wl_shm\n");
        return 4;
    }
    if (wl_display_roundtrip(display) < 0) return 5;
    if (state.formats_seen == 0) {
        fprintf(stderr, "client: no shm formats arrived\n");
        return 6;
    }

    int fd = make_memfd(BUFFER_BYTES);
    if (fd < 0) {
        fprintf(stderr, "client: memfd_create failed (errno=%d)\n", errno);
        return 7;
    }
    unsigned char *pixels = mmap(NULL, BUFFER_BYTES, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        fprintf(stderr, "client: mmap failed (errno=%d)\n", errno);
        return 8;
    }
    memset(pixels, 0xA5, BUFFER_BYTES);

    struct wl_shm_pool *pool = wl_shm_create_pool(state.shm, fd, BUFFER_BYTES);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, BUFFER_WIDTH, BUFFER_HEIGHT, BUFFER_STRIDE,
        WL_SHM_FORMAT_ARGB8888);

    /* A failure to map the descriptor on the server side comes back as a
       protocol error, not as a NULL return, so the roundtrip is what surfaces
       it. */
    if (wl_display_roundtrip(display) < 0) {
        fprintf(stderr, "client: roundtrip failed after creating the pool\n");
        return 9;
    }
    int error = wl_display_get_error(display);
    if (error) {
        fprintf(stderr, "client: protocol error %d after creating the pool\n", error);
        return 10;
    }

    printf("client: shm pool and buffer accepted by the server\n");

    wl_buffer_destroy(buffer);
    wl_shm_pool_destroy(pool);
    munmap(pixels, BUFFER_BYTES);
    close(fd);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}

/* ---------------------------------------------------------------- server -- */

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Fires when the server accepts a connection, which is the single fact that
   separates "the client never reached us" from "we never answered it". */
static int clients_seen;

static void handle_client_created(struct wl_listener *listener, void *data) {
    (void)listener;
    (void)data;
    clients_seen++;
}

static struct wl_listener client_created_listener = { .notify = handle_client_created };

/*
 * Bring the server up far enough to be listening. Split out because the
 * narrowing modes below need it without any of the client machinery.
 */
static struct wl_display *start_server(const char **socket_name_out) {
    setenv("XDG_RUNTIME_DIR", "/tmp", 1);
    struct wl_display *display = wl_display_create();
    if (!display) {
        fprintf(stderr, "server: wl_display_create failed\n");
        return NULL;
    }
    if (wl_display_init_shm(display) < 0) {
        fprintf(stderr, "server: wl_display_init_shm failed\n");
        return NULL;
    }
    const char *name = wl_display_add_socket_auto(display);
    if (!name) {
        fprintf(stderr, "server: cannot bind a socket in %s\n",
                getenv("XDG_RUNTIME_DIR"));
        return NULL;
    }
    wl_display_add_client_created_listener(display, &client_created_listener);
    if (socket_name_out) *socket_name_out = name;
    printf("server: listening on %s\n", name);
    return display;
}

/*
 * Narrowing mode: bind a socket and tear it straight back down, with no client
 * and no fork. If this is what panics, the bug is in closing a listening unix
 * socket, and everything about Wayland is a red herring.
 */
static int run_socket_only(void) {
    struct wl_display *display = start_server(NULL);
    if (!display) return 1;
    printf("socket-only: destroying the display\n");
    wl_display_destroy(display);
    printf("socket-only: PASS\n");
    return 0;
}

/*
 * Narrowing mode: let a client connect and do nothing else. Reports whether the
 * server's event loop ever accepted it. Nothing is killed, so a panic here
 * belongs to teardown rather than to signal delivery.
 */
static int run_connect_only(void) {
    const char *socket_name = NULL;
    struct wl_display *display = start_server(&socket_name);
    if (!display) return 1;

    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        struct wl_display *client = wl_display_connect(socket_name);
        if (!client) _exit(2);
        /* Hold the connection open, then leave of our own accord. */
        sleep(3);
        wl_display_disconnect(client);
        _exit(0);
    }

    struct wl_event_loop *loop = wl_display_get_event_loop(display);
    int64_t deadline = now_ms() + 5000;
    while (now_ms() < deadline) {
        wl_event_loop_dispatch(loop, 100);
        wl_display_flush_clients(display);
    }
    printf("connect-only: server accepted %d client(s)\n", clients_seen);

    int status = 0;
    waitpid(pid, &status, WNOHANG);
    printf("connect-only: destroying the display\n");
    wl_display_destroy(display);
    printf("connect-only: done\n");
    return clients_seen > 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--socket-only") == 0) return run_socket_only();
    if (argc > 1 && strcmp(argv[1], "--connect-only") == 0) return run_connect_only();
    const char *socket_name = NULL;
    struct wl_display *display = start_server(&socket_name);
    if (!display) return 1;

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "server: fork failed\n");
        return 1;
    }
    if (pid == 0) {
        /* Do NOT destroy the inherited display here. wl_display_destroy()
           unlinks the socket and its lock file, so the child would delete the
           very socket it is about to connect to -- and the server would then
           sit there accepting nobody. The child simply leaves it alone; its
           copy dies with the process. */
        _exit(run_client(socket_name));
    }

    /* Drive the event loop until the client is done, with a deadline so a
       failure is a test failure rather than a hang. */
    struct wl_event_loop *loop = wl_display_get_event_loop(display);
    int64_t deadline = now_ms() + 20000;
    int status = 0;
    int reaped = 0;
    while (now_ms() < deadline) {
        wl_event_loop_dispatch(loop, 100);
        wl_display_flush_clients(display);
        if (waitpid(pid, &status, WNOHANG) == pid) {
            reaped = 1;
            break;
        }
    }

    if (!reaped) {
        fprintf(stderr, "wayland-roundtrip-test: FAIL client did not finish "
                "(server accepted %d client(s))\n", clients_seen);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "wayland-roundtrip-test: FAIL client exited with %d\n",
                WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return 1;
    }

    wl_display_destroy(display);
    printf("wayland-roundtrip-test: PASS\n");
    return 0;
}
