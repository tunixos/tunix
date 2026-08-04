/* Acceptance test for the SDL2 port: enumerate the drivers, then open a window,
   blit a moving pattern through the software renderer and read the event queue. */
#include <SDL.h>
#include <stdio.h>
#include <string.h>

#define WIDTH 320
#define HEIGHT 200

static void list_drivers(void) {
    int count = SDL_GetNumVideoDrivers();
    printf("sdl2-test: video drivers:");
    for (int i = 0; i < count; i++) printf(" %s", SDL_GetVideoDriver(i));
    printf("\n");

    count = SDL_GetNumAudioDrivers();
    printf("sdl2-test: audio drivers:");
    for (int i = 0; i < count; i++) printf(" %s", SDL_GetAudioDriver(i));
    printf("\n");
}

static void fill(Uint32 *pixels, int frame) {
    for (int y = 0; y < HEIGHT; y++)
        for (int x = 0; x < WIDTH; x++)
            pixels[y * WIDTH + x] = (Uint32)(((x + frame) & 0xFF) << 16 |
                                             ((y + frame) & 0xFF) << 8 |
                                             ((x ^ y) & 0xFF));
}

int main(int argc, char **argv) {
    SDL_version linked;
    SDL_GetVersion(&linked);
    printf("sdl2-test: SDL %u.%u.%u\n", linked.major, linked.minor, linked.patch);
    list_drivers();

    if (argc > 1 && strcmp(argv[1], "--drivers") == 0) return 0;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        printf("sdl2-test: SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    printf("sdl2-test: using %s\n", SDL_GetCurrentVideoDriver());

    SDL_Window *window = SDL_CreateWindow("sdl2-test",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIDTH * 2, HEIGHT * 2, 0);
    if (!window) {
        printf("sdl2-test: SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, 0);
    if (!renderer) {
        printf("sdl2-test: SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    SDL_RendererInfo info;
    if (SDL_GetRendererInfo(renderer, &info) == 0)
        printf("sdl2-test: renderer %s\n", info.name);

    SDL_Texture *texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                             SDL_TEXTUREACCESS_STREAMING, WIDTH, HEIGHT);
    if (!texture) {
        printf("sdl2-test: SDL_CreateTexture failed: %s\n", SDL_GetError());
        return 1;
    }

    Uint32 start = SDL_GetTicks();
    int frames = 0;
    int running = 1;
    while (running && SDL_GetTicks() - start < 5000) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) running = 0;
            if (event.type == SDL_KEYDOWN) {
                printf("sdl2-test: key %s\n", SDL_GetKeyName(event.key.keysym.sym));
                if (event.key.keysym.sym == SDLK_ESCAPE) running = 0;
            }
            if (event.type == SDL_MOUSEBUTTONDOWN)
                printf("sdl2-test: button %d at %d,%d\n", event.button.button,
                       event.button.x, event.button.y);
        }

        Uint32 *pixels;
        int pitch;
        if (SDL_LockTexture(texture, NULL, (void **)&pixels, &pitch) == 0) {
            fill(pixels, frames);
            SDL_UnlockTexture(texture);
        }
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);
        frames++;
    }

    Uint32 elapsed = SDL_GetTicks() - start;
    printf("sdl2-test: %d frames in %u ms (%.1f fps)\n", frames, elapsed,
           elapsed ? frames * 1000.0 / elapsed : 0.0);

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
