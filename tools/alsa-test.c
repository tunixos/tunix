/*
 * alsa-test: prove alsa-lib and the Tunix sound driver agree.
 *
 * snd-test drives the kernel's ioctls directly. This one goes through the
 * library instead, which is a different and harder thing: the config parser
 * has to resolve a device name, the plug plugin has to negotiate parameters it
 * was not given, and the mixer has to enumerate control elements. Each stage
 * prints what it found, so a failure names itself.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <alsa/asoundlib.h>

#define RATE 48000U
#define CHANNELS 2U
#define TONE_HZ 440U
#define FRAMES (RATE / 4U)          /* a quarter second per pass */
#define PERIOD_FRAMES 1024U

/* A quarter of a sine, mirrored into the other three. No libm, no floats:
   this has to run on a system whose kernel only just learned to save the FPU. */
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

static int16_t *make_tone(unsigned frames) {
    int16_t *samples = calloc(frames * CHANNELS, sizeof(*samples));
    if (!samples) return NULL;
    uint32_t phase = 0;
    uint32_t step = (TONE_HZ * 64U * 1024U) / RATE;
    for (unsigned frame = 0; frame < frames; frame++) {
        int16_t value = sine(phase >> 10);
        phase += step;
        for (unsigned channel = 0; channel < CHANNELS; channel++)
            samples[frame * CHANNELS + channel] = value;
    }
    return samples;
}

static int fail(const char *stage, int error) {
    fprintf(stderr, "alsa-test: %s failed: %s\n", stage, snd_strerror(error));
    return 1;
}

/* Every card the library can see, by the same route arecord -l takes. */
static int list_cards(void) {
    int card = -1;
    int found = 0;
    while (snd_card_next(&card) == 0 && card >= 0) {
        char name[32];
        snprintf(name, sizeof(name), "hw:%d", card);
        snd_ctl_t *control = NULL;
        int status = snd_ctl_open(&control, name, 0);
        if (status < 0) return fail("snd_ctl_open", status);

        snd_ctl_card_info_t *info;
        snd_ctl_card_info_alloca(&info);
        status = snd_ctl_card_info(control, info);
        if (status < 0) {
            snd_ctl_close(control);
            return fail("snd_ctl_card_info", status);
        }
        printf("alsa-test: card %d \"%s\", driver %s, mixer %s\n", card,
               snd_ctl_card_info_get_name(info),
               snd_ctl_card_info_get_driver(info),
               snd_ctl_card_info_get_mixername(info));
        snd_ctl_close(control);
        found++;
    }
    if (!found) {
        fprintf(stderr, "alsa-test: no sound cards found\n");
        return 1;
    }
    return 0;
}

/*
 * The high-level path: a device name out of the configuration tree, parameters
 * chosen by the library, and interleaved writes. This is what an ordinary
 * application does, and it exercises the plug plugin on the way down.
 */
static int play_simple(const char *device, const int16_t *tone) {
    snd_pcm_t *pcm = NULL;
    int status = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (status < 0) return fail("snd_pcm_open", status);

    status = snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE,
                                SND_PCM_ACCESS_RW_INTERLEAVED, CHANNELS, RATE,
                                1, 200000);
    if (status < 0) {
        snd_pcm_close(pcm);
        return fail("snd_pcm_set_params", status);
    }

    unsigned actual_rate = 0;
    snd_pcm_uframes_t buffer = 0, period = 0;
    (void)snd_pcm_get_params(pcm, &buffer, &period);

    snd_pcm_hw_params_t *hw;
    snd_pcm_hw_params_alloca(&hw);
    if (snd_pcm_hw_params_current(pcm, hw) == 0)
        (void)snd_pcm_hw_params_get_rate(hw, &actual_rate, NULL);

    snd_pcm_uframes_t done = 0;
    unsigned recoveries = 0;
    while (done < FRAMES) {
        snd_pcm_sframes_t written =
            snd_pcm_writei(pcm, tone + done * CHANNELS, FRAMES - done);
        if (written == -EPIPE) {
            /* An underrun, and not necessarily a fault: the card consumes
               samples in real time while an emulated CPU refills the ring at
               whatever speed it runs at. Recovering is what an application
               does, so the test does it and counts. */
            recoveries++;
            status = snd_pcm_prepare(pcm);
            if (status < 0) {
                snd_pcm_close(pcm);
                return fail("snd_pcm_prepare after underrun", status);
            }
            continue;
        }
        if (written < 0) {
            snd_pcm_close(pcm);
            return fail("snd_pcm_writei", (int)written);
        }
        done += (snd_pcm_uframes_t)written;
    }
    status = snd_pcm_drain(pcm);
    if (status < 0) {
        snd_pcm_close(pcm);
        return fail("snd_pcm_drain", status);
    }
    printf("alsa-test: %s wrote %lu frames at %u Hz, buffer %lu period %lu, "
           "%u underrun(s)\n", device, (unsigned long)done, actual_rate,
           (unsigned long)buffer, (unsigned long)period, recoveries);
    snd_pcm_close(pcm);
    return 0;
}

/*
 * The path PipeWire takes: the ring is mapped and filled in place, and the
 * position comes back through SYNC_PTR. Nothing above the library changes, but
 * everything below it does.
 */
static int play_mapped(const char *device, const int16_t *tone) {
    snd_pcm_t *pcm = NULL;
    int status = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (status < 0) return fail("snd_pcm_open (mmap)", status);

    snd_pcm_hw_params_t *hw;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_hw_params_any(pcm, hw);
    status = snd_pcm_hw_params_set_access(pcm, hw,
                                          SND_PCM_ACCESS_MMAP_INTERLEAVED);
    if (status < 0) goto broken;
    status = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE);
    if (status < 0) goto broken;
    status = snd_pcm_hw_params_set_channels(pcm, hw, CHANNELS);
    if (status < 0) goto broken;
    unsigned rate = RATE;
    status = snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, NULL);
    if (status < 0) goto broken;
    snd_pcm_uframes_t period = PERIOD_FRAMES;
    status = snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, NULL);
    if (status < 0) goto broken;
    status = snd_pcm_hw_params(pcm, hw);
    if (status < 0) goto broken;

    status = snd_pcm_prepare(pcm);
    if (status < 0) goto broken;

    snd_pcm_uframes_t done = 0;
    unsigned recoveries = 0;
    while (done < FRAMES) {
        snd_pcm_sframes_t avail = snd_pcm_avail_update(pcm);
        if (avail == -EPIPE) {
            recoveries++;
            status = snd_pcm_prepare(pcm);
            if (status < 0) goto broken;
            continue;
        }
        if (avail < 0) { status = (int)avail; goto broken; }
        if ((snd_pcm_uframes_t)avail < period) {
            status = snd_pcm_wait(pcm, 1000);
            if (status < 0) goto broken;
            if (status == 0) { status = -ETIMEDOUT; goto broken; }
            continue;
        }

        const snd_pcm_channel_area_t *areas = NULL;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t frames = FRAMES - done;
        status = snd_pcm_mmap_begin(pcm, &areas, &offset, &frames);
        if (status < 0) goto broken;

        /* Interleaved: one area per channel over the same block, differing
           only in where the channel's first sample sits inside a frame. */
        int16_t *target = (int16_t *)areas[0].addr +
                          (areas[0].first / 16U) + offset * CHANNELS;
        memcpy(target, tone + done * CHANNELS,
               (size_t)frames * CHANNELS * sizeof(int16_t));

        snd_pcm_sframes_t committed = snd_pcm_mmap_commit(pcm, offset, frames);
        if (committed == -EPIPE) {
            recoveries++;
            status = snd_pcm_prepare(pcm);
            if (status < 0) goto broken;
            continue;
        }
        if (committed < 0) { status = (int)committed; goto broken; }
        done += (snd_pcm_uframes_t)committed;

        if (snd_pcm_state(pcm) == SND_PCM_STATE_PREPARED) {
            status = snd_pcm_start(pcm);
            if (status < 0) goto broken;
        }
    }

    status = snd_pcm_drain(pcm);
    if (status < 0) goto broken;
    printf("alsa-test: %s mapped %lu frames at %u Hz, period %lu, "
           "%u underrun(s)\n", device, (unsigned long)done, rate,
           (unsigned long)period, recoveries);
    snd_pcm_close(pcm);
    return 0;

broken:
    snd_pcm_close(pcm);
    return fail("mmap playback", status);
}

/* The mixer, which is the control device seen through simple-element API. */
static int show_mixer(void) {
    snd_mixer_t *mixer = NULL;
    int status = snd_mixer_open(&mixer, 0);
    if (status < 0) return fail("snd_mixer_open", status);
    if ((status = snd_mixer_attach(mixer, "hw:0")) < 0) goto broken;
    if ((status = snd_mixer_selem_register(mixer, NULL, NULL)) < 0) goto broken;
    if ((status = snd_mixer_load(mixer)) < 0) goto broken;

    int elements = 0;
    for (snd_mixer_elem_t *element = snd_mixer_first_elem(mixer); element;
         element = snd_mixer_elem_next(element)) {
        if (!snd_mixer_selem_is_active(element)) continue;
        long value = 0, minimum = 0, maximum = 0;
        if (snd_mixer_selem_has_playback_volume(element)) {
            snd_mixer_selem_get_playback_volume_range(element, &minimum, &maximum);
            snd_mixer_selem_get_playback_volume(element,
                                                SND_MIXER_SCHN_FRONT_LEFT, &value);
            printf("alsa-test: mixer \"%s\" volume %ld of %ld..%ld\n",
                   snd_mixer_selem_get_name(element), value, minimum, maximum);
        } else {
            printf("alsa-test: mixer \"%s\"\n", snd_mixer_selem_get_name(element));
        }
        elements++;
    }
    snd_mixer_close(mixer);
    if (!elements) {
        fprintf(stderr, "alsa-test: the mixer has no elements\n");
        return 1;
    }
    return 0;

broken:
    snd_mixer_close(mixer);
    return fail("mixer", status);
}

int main(void) {
    printf("alsa-test: alsa-lib %s\n", snd_asoundlib_version());

    int16_t *tone = make_tone(FRAMES);
    if (!tone) {
        fprintf(stderr, "alsa-test: out of memory\n");
        return 1;
    }

    int status = list_cards();
    if (!status) status = play_simple("default", tone);
    if (!status) status = play_simple("hw:0,0", tone);
    if (!status) status = play_mapped("hw:0,0", tone);
    if (!status) status = show_mixer();
    free(tone);

    printf("alsa-test: %s\n", status ? "FAIL" : "PASS");
    return status;
}
