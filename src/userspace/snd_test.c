/*
 * snd-test: play a tone through /dev/snd, using the ALSA ioctls directly.
 *
 * The point is to exercise the kernel path alsa-lib will take -- refine,
 * hw_params, sw_params, prepare, write, drain -- without alsa-lib, so the
 * driver can be proven before the library that depends on it is ported.
 */
#include <stddef.h>
#include <stdint.h>
#include "tunix_libc.h"
#include <tunix/asound.h>

#define CONTROL_PATH "/dev/snd/controlC0"
#define PLAYBACK_PATH "/dev/snd/pcmC0D0p"

#define RATE 48000U
#define CHANNELS 2U
#define PERIOD_FRAMES 1024U
#define PERIODS 4U
#define TONE_HZ 440U
#define SECONDS 1U

/* One quarter of a sine, scaled to a quiet amplitude; the other three are
   reflections of it. No floating point anywhere in this system. */
static const int16_t quarter[17] = {
    0, 784, 1561, 2322, 3061, 3771, 4445, 5075, 5657,
    6184, 6652, 7055, 7391, 7656, 7846, 7961, 8000
};

static int16_t sine(unsigned phase) {
    phase &= 63U;
    if (phase < 16U) return quarter[phase];
    if (phase < 32U) return quarter[32U - phase];
    if (phase < 48U) return (int16_t)-quarter[phase - 32U];
    return (int16_t)-quarter[64U - phase];
}

static void fail(const char *message, long code) {
    t_puts("snd-test: ");
    t_puts(message);
    t_puts(" failed, error ");
    t_print_long(code);
    t_puts("\n");
    t_exit(1);
}

static struct snd_interval *interval_of(struct snd_pcm_hw_params *params,
                                        unsigned var) {
    return &params->intervals[var - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}

/* Start from "anything", which is what alsa-lib sends before it narrows. */
static void params_any(struct snd_pcm_hw_params *params) {
    t_memset(params, 0, sizeof(*params));
    for (unsigned index = 0; index < SNDRV_PCM_HW_PARAM_MASK_COUNT; index++)
        for (unsigned word = 0; word < SNDRV_MASK_WORDS; word++)
            params->masks[index].bits[word] = 0xFFFFFFFFU;
    for (unsigned index = 0; index < SNDRV_PCM_HW_PARAM_INTERVAL_COUNT; index++) {
        params->intervals[index].min = 0;
        params->intervals[index].max = 0xFFFFFFFFU;
    }
    params->rmask = 0xFFFFFFFFU;
}

static void set_mask(struct snd_pcm_hw_params *params, unsigned var, unsigned bit) {
    for (unsigned word = 0; word < SNDRV_MASK_WORDS; word++)
        params->masks[var].bits[word] = 0;
    params->masks[var].bits[bit / 32U] = 1U << (bit % 32U);
}

static void set_interval(struct snd_pcm_hw_params *params, unsigned var,
                         unsigned value) {
    struct snd_interval *interval = interval_of(params, var);
    interval->min = value;
    interval->max = value;
    interval->integer = 1;
}

static unsigned get_interval(struct snd_pcm_hw_params *params, unsigned var) {
    return interval_of(params, var)->min;
}

/* One period of tone into an interleaved buffer, carrying the phase along. */
static void fill_tone(int16_t *destination, unsigned frames, uint32_t *phase,
                      uint32_t step) {
    for (unsigned frame = 0; frame < frames; frame++) {
        int16_t sample = sine(*phase >> 10);
        *phase += step;
        for (unsigned channel = 0; channel < CHANNELS; channel++)
            destination[frame * CHANNELS + channel] = sample;
    }
}

static void configure(int fd, unsigned access, unsigned *buffer_frames,
                      unsigned long *boundary) {
    struct snd_pcm_hw_params params;
    params_any(&params);
    set_mask(&params, SNDRV_PCM_HW_PARAM_ACCESS, access);
    set_mask(&params, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    set_mask(&params, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    set_interval(&params, SNDRV_PCM_HW_PARAM_RATE, RATE);
    set_interval(&params, SNDRV_PCM_HW_PARAM_CHANNELS, CHANNELS);
    set_interval(&params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, PERIOD_FRAMES);
    set_interval(&params, SNDRV_PCM_HW_PARAM_PERIODS, PERIODS);

    if (t_ioctl(fd, SND_IOC(SND_IOC_READ | SND_IOC_WRITE, 'A',
                            SNDRV_PCM_IOCTL_NR_HW_REFINE, sizeof(params)),
                &params) < 0)
        fail("HW_REFINE", -1);
    if (t_ioctl(fd, SND_IOC(SND_IOC_READ | SND_IOC_WRITE, 'A',
                            SNDRV_PCM_IOCTL_NR_HW_PARAMS, sizeof(params)),
                &params) < 0)
        fail("HW_PARAMS", -1);
    *buffer_frames = get_interval(&params, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);

    struct snd_pcm_sw_params software;
    t_memset(&software, 0, sizeof(software));
    software.avail_min = PERIOD_FRAMES;
    /* Start as soon as the ring is full, and never stop by itself. */
    software.start_threshold = *buffer_frames;
    software.stop_threshold = *buffer_frames;
    if (t_ioctl(fd, SND_IOC(SND_IOC_READ | SND_IOC_WRITE, 'A',
                            SNDRV_PCM_IOCTL_NR_SW_PARAMS, sizeof(software)),
                &software) < 0)
        fail("SW_PARAMS", -1);
    /* The kernel owns the wrapping point and reports it back. */
    *boundary = software.boundary;

    if (t_ioctl(fd, SND_IOC(SND_IOC_NONE, 'A', SNDRV_PCM_IOCTL_NR_PREPARE, 0),
                NULL) < 0)
        fail("PREPARE", -1);
}

/*
 * The path PipeWire takes: the ring is mapped, filled in place, and the play
 * position is exchanged through SYNC_PTR rather than through read and write.
 */
static void play_mapped(int fd, unsigned buffer_frames, unsigned long boundary,
                        unsigned long total) {
    unsigned long bytes = (unsigned long)buffer_frames * CHANNELS * sizeof(int16_t);
    int16_t *ring = t_mmap(NULL, bytes, T_PROT_READ | T_PROT_WRITE,
                           T_MAP_SHARED, fd, SNDRV_PCM_MMAP_OFFSET_DATA);
    if (ring == T_MAP_FAILED) fail("mmap", -1);

    unsigned long sync_request = SND_IOC(SND_IOC_READ | SND_IOC_WRITE, 'A',
                                         SNDRV_PCM_IOCTL_NR_SYNC_PTR,
                                         sizeof(struct snd_pcm_sync_ptr));
    struct snd_pcm_sync_ptr sync;
    unsigned long applied = 0;
    uint32_t phase = 0;
    uint32_t step = (TONE_HZ * 64U * 1024U) / RATE;

    for (unsigned long done = 0; done < total; ) {
        t_memset(&sync, 0, sizeof(sync));
        sync.flags = SNDRV_PCM_SYNC_PTR_HWSYNC;
        sync.c.control.appl_ptr = applied;
        sync.c.control.avail_min = PERIOD_FRAMES;
        if (t_ioctl(fd, sync_request, &sync) < 0) fail("SYNC_PTR", -1);

        unsigned long used = (applied + boundary - sync.s.status.hw_ptr) % boundary;
        unsigned long avail = used > buffer_frames ? 0 : buffer_frames - used;
        if (avail < PERIOD_FRAMES) {
            struct t_pollfd waiting = { .fd = fd, .events = T_POLLOUT, .revents = 0 };
            if (t_poll(&waiting, 1, 1000) <= 0) fail("poll", -1);
            continue;
        }

        unsigned long offset = (applied % buffer_frames) * CHANNELS;
        fill_tone(ring + offset, PERIOD_FRAMES, &phase, step);
        applied = (applied + PERIOD_FRAMES) % boundary;
        done += PERIOD_FRAMES;
    }

    t_memset(&sync, 0, sizeof(sync));
    sync.flags = SNDRV_PCM_SYNC_PTR_HWSYNC;
    sync.c.control.appl_ptr = applied;
    sync.c.control.avail_min = PERIOD_FRAMES;
    if (t_ioctl(fd, sync_request, &sync) < 0) fail("SYNC_PTR", -1);
    if (sync.s.status.state != SNDRV_PCM_STATE_RUNNING) {
        t_puts("snd-test: mmap stream is not running, state ");
        t_print_long(sync.s.status.state);
        t_puts("\n");
        t_exit(1);
    }
    if (t_ioctl(fd, SND_IOC(SND_IOC_NONE, 'A', SNDRV_PCM_IOCTL_NR_DRAIN, 0),
                NULL) < 0)
        fail("DRAIN", -1);
    (void)t_munmap(ring, bytes);
}

static void show_card(void) {
    int fd = t_open(CONTROL_PATH, T_O_RDWR, 0);
    if (fd < 0) fail("open " CONTROL_PATH, fd);
    struct snd_ctl_card_info info;
    if (t_ioctl(fd, SND_IOC(SND_IOC_READ, 'U', SNDRV_CTL_IOCTL_NR_CARD_INFO,
                            sizeof(info)), &info) < 0)
        fail("CARD_INFO", -1);
    t_puts("snd-test: card \"");
    t_puts((const char *)info.name);
    t_puts("\", driver ");
    t_puts((const char *)info.driver);
    t_puts(", mixer ");
    t_puts((const char *)info.mixername);
    t_puts("\n");
    t_close(fd);
}

int main(void) {
    show_card();

    int fd = t_open(PLAYBACK_PATH, T_O_RDWR, 0);
    if (fd < 0) fail("open " PLAYBACK_PATH, fd);

    int version = 0;
    if (t_ioctl(fd, SNDRV_PCM_IOCTL_PVERSION, &version) < 0) fail("PVERSION", -1);
    t_puts("snd-test: protocol ");
    t_print_long((version >> 16) & 0xFF);
    t_puts(".");
    t_print_long((version >> 8) & 0xFF);
    t_puts(".");
    t_print_long(version & 0xFF);
    t_puts("\n");

    unsigned buffer_frames = 0;
    unsigned long boundary = 0;
    unsigned long total = (unsigned long)RATE * SECONDS;
    configure(fd, SNDRV_PCM_ACCESS_RW_INTERLEAVED, &buffer_frames, &boundary);

    t_puts("snd-test: ");
    t_print_long(RATE);
    t_puts(" Hz, ");
    t_print_long(CHANNELS);
    t_puts(" channels, buffer ");
    t_print_long(buffer_frames);
    t_puts(" frames\n");

    static int16_t block[PERIOD_FRAMES * CHANNELS];
    uint32_t phase = 0;
    /* 6.10 fixed point: 64 table entries per cycle, scaled up so the step is
       exact enough over a couple of seconds. */
    uint32_t step = (TONE_HZ * 64U * 1024U) / RATE;

    for (unsigned long done = 0; done < total; done += PERIOD_FRAMES) {
        fill_tone(block, PERIOD_FRAMES, &phase, step);
        long written = t_write(fd, block, sizeof(block));
        if (written < 0) fail("write", written);
    }
    if (t_ioctl(fd, SND_IOC(SND_IOC_NONE, 'A', SNDRV_PCM_IOCTL_NR_DRAIN, 0),
                NULL) < 0)
        fail("DRAIN", -1);
    t_puts("snd-test: write path played ");
    t_print_long(SECONDS);
    t_puts(" s at ");
    t_print_long(TONE_HZ);
    t_puts(" Hz\n");

    if (t_ioctl(fd, SND_IOC(SND_IOC_NONE, 'A', SNDRV_PCM_IOCTL_NR_HW_FREE, 0),
                NULL) < 0)
        fail("HW_FREE", -1);
    configure(fd, SNDRV_PCM_ACCESS_MMAP_INTERLEAVED, &buffer_frames, &boundary);

    struct snd_pcm_channel_info channel;
    t_memset(&channel, 0, sizeof(channel));
    if (t_ioctl(fd, SND_IOC(SND_IOC_READ | SND_IOC_WRITE, 'A',
                            SNDRV_PCM_IOCTL_NR_CHANNEL_INFO, sizeof(channel)),
                &channel) < 0)
        fail("CHANNEL_INFO", -1);

    play_mapped(fd, buffer_frames, boundary, total);
    t_puts("snd-test: mmap path played ");
    t_print_long(SECONDS);
    t_puts(" s, frame step ");
    t_print_long((long)channel.step);
    t_puts(" bits\n");

    t_close(fd);
    return 0;
}
