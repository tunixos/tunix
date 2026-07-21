/*
 * drm-test -- drive /dev/dri/card0 through libdrm, the way any KMS client does.
 *
 * This is the standalone proof that the DRM device works, with weston left out
 * of the picture entirely: the same call sequence kmscube and weston's drm
 * backend use, in about a hundred lines.
 *
 *   drmModeGetResources        does the device describe a CRTC and a connector?
 *   drmModeGetConnector        is something connected, with a mode?
 *   DRM_IOCTL_MODE_CREATE_DUMB can we allocate a CPU-drawable buffer?
 *   mmap                       can we map it and draw into it?
 *   drmModeAddFB               can we wrap it as a scanout framebuffer?
 *   drmModeSetCrtc             does it reach the screen?
 *
 * The pattern it draws is deliberately obvious: were this to appear on a real
 * display, colour bands mean the pixels arrived in the order intended.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

static int failures;

static void check(int condition, const char *what) {
    if (condition) {
        printf("drm-test: ok   %s\n", what);
    } else {
        printf("drm-test: FAIL %s (errno=%d %s)\n", what, errno, strerror(errno));
        failures++;
    }
}

/* A value with no meaning beyond being recognisable on the way back. */
#define FLIP_COOKIE 0x1234ABCDUL

static int flip_seen;
static unsigned long flip_user_data;

static void flip_handler(int fd, unsigned sequence, unsigned tv_sec,
                         unsigned tv_usec, void *user_data) {
    (void)fd; (void)sequence; (void)tv_sec; (void)tv_usec;
    flip_seen = 1;
    flip_user_data = (unsigned long)user_data;
}

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    check(fd >= 0, "open /dev/dri/card0");
    if (fd < 0) return 1;

    drmVersionPtr version = drmGetVersion(fd);
    check(version != NULL, "drmGetVersion");
    if (version) {
        printf("drm-test: driver=%s %d.%d.%d\n", version->name,
               version->version_major, version->version_minor,
               version->version_patchlevel);
        drmFreeVersion(version);
    }

    uint64_t has_dumb = 0;
    check(drmGetCap(fd, DRM_CAP_DUMB_BUFFER, &has_dumb) == 0 && has_dumb,
          "the device advertises dumb buffers");

    drmModeRes *resources = drmModeGetResources(fd);
    check(resources != NULL, "drmModeGetResources");
    if (!resources) { close(fd); return 1; }
    check(resources->count_crtcs >= 1 && resources->count_connectors >= 1,
          "at least one CRTC and one connector");

    drmModeConnector *connector =
        drmModeGetConnector(fd, resources->connectors[0]);
    check(connector != NULL, "drmModeGetConnector");
    if (!connector) { drmModeFreeResources(resources); close(fd); return 1; }
    check(connector->connection == DRM_MODE_CONNECTED, "the connector is connected");
    check(connector->count_modes >= 1, "the connector reports a mode");
    if (connector->count_modes < 1) return 1;

    drmModeModeInfo mode = connector->modes[0];
    printf("drm-test: mode %s %ux%u\n", mode.name, mode.hdisplay, mode.vdisplay);

    /* Allocate a buffer the CPU can draw into. */
    struct drm_mode_create_dumb create = {
        .width = mode.hdisplay, .height = mode.vdisplay, .bpp = 32,
    };
    check(drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) == 0,
          "create a dumb buffer");
    if (!create.handle) return 1;

    struct drm_mode_map_dumb map = { .handle = create.handle };
    check(drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map) == 0, "map the dumb buffer");

    uint8_t *pixels = mmap(NULL, create.size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, (off_t)map.offset);
    check(pixels != MAP_FAILED, "mmap the dumb buffer");
    if (pixels == MAP_FAILED) return 1;

    /* Horizontal colour bands: obviously wrong if the rows land out of order. */
    for (uint32_t y = 0; y < create.height; y++) {
        uint32_t *row = (uint32_t *)(pixels + (size_t)y * create.pitch);
        uint32_t band = (y * 6) / create.height;
        static const uint32_t colours[6] = {
            0x00FF0000, 0x0000FF00, 0x000000FF,
            0x00FFFF00, 0x0000FFFF, 0x00FFFFFF,
        };
        for (uint32_t x = 0; x < create.width; x++) row[x] = colours[band];
    }
    /* A marker the driver's blit must carry through untouched. */
    ((uint32_t *)pixels)[0] = 0x00ABCDEF;

    uint32_t fb_id = 0;
    check(drmModeAddFB(fd, create.width, create.height, 24, 32, create.pitch,
                       create.handle, &fb_id) == 0 && fb_id,
          "drmModeAddFB");

    check(drmModeSetCrtc(fd, resources->crtcs[0], fb_id, 0, 0,
                         &connector->connector_id, 1, &mode) == 0,
          "drmModeSetCrtc puts the framebuffer on screen");

    /* Page flip to the same buffer: the presentation path again, and what a
       compositor does every frame. */
    check(drmModePageFlip(fd, resources->crtcs[0], fb_id, 0, NULL) == 0,
          "drmModePageFlip");

    /*
     * The same flip again, but asking for a completion event -- which is how
     * every compositor actually drives its frame loop. libdrm reads the event
     * off the descriptor and calls back; a driver without an event queue would
     * leave drmHandleEvent blocking here forever.
     */
    drmEventContext context = { .version = 2, .page_flip_handler = flip_handler };

    flip_seen = 0;
    flip_user_data = 0;
    check(drmModePageFlip(fd, resources->crtcs[0], fb_id,
                          DRM_MODE_PAGE_FLIP_EVENT,
                          (void *)FLIP_COOKIE) == 0,
          "drmModePageFlip with a completion event");
    check(drmHandleEvent(fd, &context) == 0 && flip_seen,
          "the completion event arrives and is dispatched");
    /* The cookie must survive the round trip: it is how a compositor tells its
       own outputs apart. */
    check(flip_user_data == FLIP_COOKIE, "the event carries back its user data");

    drmModeRmFB(fd, fb_id);
    munmap(pixels, create.size);
    struct drm_mode_destroy_dumb destroy = { .handle = create.handle };
    check(drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy) == 0,
          "destroy the dumb buffer");

    drmModeFreeConnector(connector);
    drmModeFreeResources(resources);
    close(fd);

    if (failures) {
        printf("drm-test: FAIL (%d)\n", failures);
        return 1;
    }
    printf("drm-test: PASS\n");
    return 0;
}
