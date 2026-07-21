#ifndef TUNIX_DRM_H
#define TUNIX_DRM_H

#include <stddef.h>
#include <stdint.h>

struct file;
struct vfs_node;

/*
 * A DRM/KMS device with no GPU behind it, in the spirit of Linux's simpledrm:
 * the scanout is the framebuffer the bootloader handed us, and the only memory
 * objects are dumb buffers -- plain pages userspace maps and draws into with
 * the CPU.
 *
 * This exists because /dev/fb0 and the TUNIX_FBIO_* ioctls are ours alone.
 * Everything in the Linux graphics world -- mesa's GBM, weston's drm backend,
 * kmscube -- talks to /dev/dri/card0 instead. Providing that node is what makes
 * unmodified graphics software able to run here at all.
 *
 * Deliberately absent: GEM sharing between processes, PRIME/dma-buf, atomic
 * modesetting, and any notion of a second CRTC or connector. There is one
 * fixed mode, the one the display is already in.
 */

void drm_init(void);
int drm_available(void);

int64_t drm_node_ioctl(struct vfs_node *node, unsigned long request,
                       uint64_t user_argument);
int64_t drm_file_ioctl(struct file *file, unsigned long request,
                       uint64_t user_argument);
int64_t drm_device_mmap(struct vfs_node *node, struct file *file,
                        uint64_t cr3, uint64_t virtual_address,
                        uint64_t length, uint64_t offset,
                        uint64_t page_flags);
int64_t drm_device_read(struct vfs_node *node, uint64_t offset,
                        size_t size, void *buffer);
int drm_device_read_ready(struct vfs_node *node);
void drm_file_close(struct file *file);

#endif
