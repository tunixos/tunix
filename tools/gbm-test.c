/*
 * gbm-test -- the GBM/EGL sequence a compositor's GL renderer runs through.
 *
 * Weston does all of this inside drm_output_init_egl() and reports one line if
 * anything goes wrong -- or, when something returns a pointer nobody checks,
 * nothing at all. This walks the same path a call at a time and says which one
 * failed, on a device with no GPU, where mesa is expected to fall back to
 * kms_swrast: DRM dumb buffers rasterised by softpipe.
 *
 *   gbm_create_device            can mesa drive /dev/dri/card0 at all?
 *   eglGetPlatformDisplay(GBM)   is the GBM platform compiled in and usable?
 *   eglInitialize / config       does a scanout-capable config exist?
 *   gbm_surface_create           can a front/back buffer pair be allocated?
 *   eglCreatePlatformWindowSurfaceEXT   the call weston crashes in
 *   draw + eglSwapBuffers        does a frame actually land in a buffer?
 *   gbm_surface_lock_front_buffer       is there a bo to scan out?
 *   gbm_bo_get_handle            does it have a GEM handle for drmModeAddFB?
 */

/* dladdr and Dl_info are extensions; musl hides them without this. */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <dlfcn.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static int failures;

static void check(int condition, const char *what) {
    if (condition) {
        printf("gbm-test: ok   %s\n", what);
    } else {
        printf("gbm-test: FAIL %s (errno=%d %s, egl=0x%x)\n", what, errno,
               strerror(errno), (unsigned)eglGetError());
        failures++;
    }
}

/*
 * Where each library landed. Tunix has no /proc/<pid>/maps, so when the kernel
 * reports a fault at some RIP there is otherwise no way to say which library it
 * is in -- and mesa is several. Subtract the base printed here from the RIP and
 * the offset goes straight into addr2line against the unstripped build.
 */
static void print_library_base(const char *what, void *symbol) {
    Dl_info info;
    if (symbol && dladdr(symbol, &info) && info.dli_fbase) {
        printf("gbm-test: %-10s base=%p  (%s)\n", what, info.dli_fbase,
               info.dli_fname ? info.dli_fname : "?");
    } else {
        printf("gbm-test: %-10s base=unknown\n", what);
    }
}

int main(void) {
    print_library_base("libEGL", (void *)eglInitialize);
    print_library_base("libgbm", (void *)gbm_create_device);
    print_library_base("libGLESv2", (void *)glClear);
    /* The gallium megadriver is dlopen()ed by the others, so reach it through
       a handle rather than a symbol we link against. */
    void *gallium = dlopen("libgallium-26.2.0-rc1.so", RTLD_LAZY | RTLD_NOLOAD);
    if (gallium) {
        void *symbol = dlsym(gallium, "driCreateNewScreen3");
        if (!symbol) symbol = dlsym(gallium, "__driDriverGetExtensions_kms_swrast");
        print_library_base("libgallium", symbol);
    } else {
        printf("gbm-test: libgallium not loaded yet\n");
    }

    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    check(fd >= 0, "open /dev/dri/card0");
    if (fd < 0) return 1;

    struct gbm_device *gbm = gbm_create_device(fd);
    check(gbm != NULL, "gbm_create_device");
    if (!gbm) return 1;
    printf("gbm-test: backend=%s\n", gbm_device_get_backend_name(gbm));

    /* XRGB8888 is the only format the scanout takes. */
    const uint32_t format = GBM_FORMAT_XRGB8888;
    check(gbm_device_is_format_supported(gbm, format, GBM_BO_USE_SCANOUT |
                                         GBM_BO_USE_RENDERING),
          "XRGB8888 is usable for scanout and rendering");

    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)
        eglGetProcAddress("eglGetPlatformDisplayEXT");
    check(get_platform_display != NULL, "eglGetPlatformDisplayEXT is available");
    if (!get_platform_display) return 1;

    EGLDisplay display = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    check(display != EGL_NO_DISPLAY, "eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR)");
    if (display == EGL_NO_DISPLAY) return 1;

    EGLint major = 0, minor = 0;
    check(eglInitialize(display, &major, &minor) == EGL_TRUE, "eglInitialize");
    printf("gbm-test: EGL %d.%d vendor=%s\n", major, minor,
           eglQueryString(display, EGL_VENDOR));

    check(eglBindAPI(EGL_OPENGL_ES_API) == EGL_TRUE, "eglBindAPI(GLES)");

    /* EGL_WINDOW_BIT is the part that matters: a config without it cannot back
       a gbm surface, and asking for one is how weston picks its config. */
    static const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 0,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE
    };
    EGLConfig configs[64];
    EGLint config_count = 0;
    check(eglChooseConfig(display, config_attributes, configs,
                          (EGLint)(sizeof(configs) / sizeof(configs[0])),
                          &config_count) && config_count > 0,
          "eglChooseConfig for a window surface");
    if (!config_count) return 1;

    /*
     * Take the config whose native visual *is* the surface format. Asking for
     * 8 bits per channel only sets a minimum, so EGL's first answer here is a
     * 10-bit config (XR30) -- and a config that does not match the surface is
     * rejected later with EGL_BAD_MATCH. This is the same match weston makes.
     */
    EGLConfig config = NULL;
    for (EGLint index = 0; index < config_count; index++) {
        EGLint visual = 0;
        eglGetConfigAttrib(display, configs[index], EGL_NATIVE_VISUAL_ID, &visual);
        if ((uint32_t)visual == format) { config = configs[index]; break; }
    }
    printf("gbm-test: %d configs offered\n", (int)config_count);
    check(config != NULL, "one of them has the surface's native visual");
    if (!config) return 1;

    struct gbm_surface *surface =
        gbm_surface_create(gbm, 640, 480, format,
                           GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    check(surface != NULL, "gbm_surface_create");
    if (!surface) return 1;

    PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC create_window_surface =
        (PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC)
        eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
    check(create_window_surface != NULL,
          "eglCreatePlatformWindowSurfaceEXT is available");
    if (!create_window_surface) return 1;

    EGLSurface egl_surface = create_window_surface(display, config, surface, NULL);
    check(egl_surface != EGL_NO_SURFACE, "eglCreatePlatformWindowSurfaceEXT");
    if (egl_surface == EGL_NO_SURFACE) return 1;

    static const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE
    };
    EGLContext context =
        eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    check(context != EGL_NO_CONTEXT, "eglCreateContext");
    if (context == EGL_NO_CONTEXT) return 1;

    /* By now the driver is loaded, so its base address is finally resolvable --
       and this is the call that faults. */
    void *loaded = dlopen("libgallium-26.2.0-rc1.so", RTLD_LAZY | RTLD_NOLOAD);
    if (loaded) {
        void *symbol = dlsym(loaded, "driCreateNewScreen3");
        if (!symbol) symbol = dlsym(loaded, "__driDriverGetExtensions_kms_swrast");
        print_library_base("libgallium", symbol);
    }
    fflush(stdout);

    check(eglMakeCurrent(display, egl_surface, egl_surface, context) == EGL_TRUE,
          "eglMakeCurrent");
    printf("gbm-test: GL_RENDERER=%s\n", (const char *)glGetString(GL_RENDERER));

    glClearColor(0.1f, 0.4f, 0.8f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    check(glGetError() == GL_NO_ERROR, "a frame renders without a GL error");

    check(eglSwapBuffers(display, egl_surface) == EGL_TRUE, "eglSwapBuffers");

    /* This is what the compositor scans out: the buffer the swap just made
       front. Without a GEM handle it cannot become a KMS framebuffer. */
    struct gbm_bo *bo = gbm_surface_lock_front_buffer(surface);
    check(bo != NULL, "gbm_surface_lock_front_buffer");
    if (bo) {
        union gbm_bo_handle handle = gbm_bo_get_handle(bo);
        uint32_t stride = gbm_bo_get_stride(bo);
        printf("gbm-test: bo handle=%u stride=%u %ux%u\n",
               handle.u32, stride, gbm_bo_get_width(bo), gbm_bo_get_height(bo));
        check(handle.u32 != 0, "the front buffer has a GEM handle");
        check(stride >= 640u * 4u, "the front buffer stride covers the width");
        gbm_surface_release_buffer(surface, bo);
    }

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, egl_surface);
    gbm_surface_destroy(surface);
    eglTerminate(display);
    gbm_device_destroy(gbm);
    close(fd);

    if (failures) {
        printf("gbm-test: FAIL (%d)\n", failures);
        return 1;
    }
    printf("gbm-test: PASS\n");
    return 0;
}
