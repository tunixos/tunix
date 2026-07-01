#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <png.h>
#include <turbojpeg.h>
#include <zlib.h>

static int test_zlib(void) {
    static const unsigned char input[] =
        "Tunix shared zlib runtime verification payload";
    unsigned char compressed[256];
    unsigned char restored[256];
    uLongf compressed_size = sizeof(compressed);
    uLongf restored_size = sizeof(restored);

    if (compress2(compressed, &compressed_size, input, sizeof(input),
                  Z_BEST_COMPRESSION) != Z_OK) {
        fprintf(stderr, "shared-image-codecs-test: zlib compression failed\n");
        return 1;
    }
    if (uncompress(restored, &restored_size, compressed, compressed_size) != Z_OK) {
        fprintf(stderr, "shared-image-codecs-test: zlib decompression failed\n");
        return 1;
    }
    if (restored_size != sizeof(input) || memcmp(restored, input, sizeof(input)) != 0) {
        fprintf(stderr, "shared-image-codecs-test: zlib round trip mismatch\n");
        return 1;
    }
    return 0;
}

static int test_png(void) {
    static const unsigned char pixels[] = {
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    };
    unsigned char decoded[sizeof(pixels)];
    png_image writer;
    png_image reader;
    png_alloc_size_t encoded_size = 0;
    unsigned char *encoded = NULL;
    int result = 1;

    memset(&writer, 0, sizeof(writer));
    writer.version = PNG_IMAGE_VERSION;
    writer.width = 2;
    writer.height = 2;
    writer.format = PNG_FORMAT_RGBA;

    if (!png_image_write_to_memory(&writer, NULL, &encoded_size, 0,
                                   pixels, 0, NULL)) {
        fprintf(stderr, "shared-image-codecs-test: libpng size query failed: %s\n",
                writer.message);
        goto out;
    }

    encoded = malloc(encoded_size);
    if (encoded == NULL) {
        fprintf(stderr, "shared-image-codecs-test: libpng allocation failed\n");
        goto out;
    }

    if (!png_image_write_to_memory(&writer, encoded, &encoded_size, 0,
                                   pixels, 0, NULL)) {
        fprintf(stderr, "shared-image-codecs-test: libpng encoding failed: %s\n",
                writer.message);
        goto out;
    }

    memset(&reader, 0, sizeof(reader));
    reader.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&reader, encoded, encoded_size)) {
        fprintf(stderr, "shared-image-codecs-test: libpng read begin failed: %s\n",
                reader.message);
        goto out;
    }
    reader.format = PNG_FORMAT_RGBA;
    if (!png_image_finish_read(&reader, NULL, decoded, 0, NULL)) {
        fprintf(stderr, "shared-image-codecs-test: libpng decoding failed: %s\n",
                reader.message);
        png_image_free(&reader);
        goto out;
    }
    png_image_free(&reader);

    if (memcmp(decoded, pixels, sizeof(pixels)) != 0) {
        fprintf(stderr, "shared-image-codecs-test: libpng round trip mismatch\n");
        goto out;
    }

    result = 0;
out:
    png_image_free(&writer);
    free(encoded);
    return result;
}

static int test_libjpeg(void) {
    static const unsigned char pixels[] = {
        255, 0, 0,   0, 255, 0,
        0, 0, 255,   255, 255, 255,
    };
    struct jpeg_compress_struct compressor;
    struct jpeg_decompress_struct decompressor;
    struct jpeg_error_mgr compressor_error;
    struct jpeg_error_mgr decompressor_error;
    unsigned char *encoded = NULL;
    unsigned long encoded_size = 0;
    unsigned char decoded[sizeof(pixels)];
    size_t decoded_offset = 0;
    JSAMPROW row[1];

    compressor.err = jpeg_std_error(&compressor_error);
    jpeg_create_compress(&compressor);
    jpeg_mem_dest(&compressor, &encoded, &encoded_size);
    compressor.image_width = 2;
    compressor.image_height = 2;
    compressor.input_components = 3;
    compressor.in_color_space = JCS_RGB;
    jpeg_set_defaults(&compressor);
    jpeg_set_quality(&compressor, 100, TRUE);
    jpeg_start_compress(&compressor, TRUE);
    while (compressor.next_scanline < compressor.image_height) {
        row[0] = (JSAMPROW)&pixels[compressor.next_scanline * 2U * 3U];
        if (jpeg_write_scanlines(&compressor, row, 1) != 1) {
            fprintf(stderr, "shared-image-codecs-test: libjpeg encoding failed\n");
            jpeg_destroy_compress(&compressor);
            free(encoded);
            return 1;
        }
    }
    jpeg_finish_compress(&compressor);
    jpeg_destroy_compress(&compressor);

    decompressor.err = jpeg_std_error(&decompressor_error);
    jpeg_create_decompress(&decompressor);
    jpeg_mem_src(&decompressor, encoded, encoded_size);
    if (jpeg_read_header(&decompressor, TRUE) != JPEG_HEADER_OK) {
        fprintf(stderr, "shared-image-codecs-test: libjpeg header read failed\n");
        jpeg_destroy_decompress(&decompressor);
        free(encoded);
        return 1;
    }
    decompressor.out_color_space = JCS_RGB;
    jpeg_start_decompress(&decompressor);
    if (decompressor.output_width != 2 || decompressor.output_height != 2 ||
        decompressor.output_components != 3) {
        fprintf(stderr, "shared-image-codecs-test: libjpeg dimensions mismatch\n");
        jpeg_destroy_decompress(&decompressor);
        free(encoded);
        return 1;
    }
    while (decompressor.output_scanline < decompressor.output_height) {
        row[0] = &decoded[decoded_offset];
        if (jpeg_read_scanlines(&decompressor, row, 1) != 1) {
            fprintf(stderr, "shared-image-codecs-test: libjpeg decoding failed\n");
            jpeg_destroy_decompress(&decompressor);
            free(encoded);
            return 1;
        }
        decoded_offset += decompressor.output_width * decompressor.output_components;
    }
    jpeg_finish_decompress(&decompressor);
    jpeg_destroy_decompress(&decompressor);
    free(encoded);

    if (decoded_offset != sizeof(decoded)) {
        fprintf(stderr, "shared-image-codecs-test: libjpeg decoded size mismatch\n");
        return 1;
    }
    return 0;
}

static int test_turbojpeg(void) {
    tjhandle handle = tj3Init(TJINIT_COMPRESS);
    if (handle == NULL) {
        fprintf(stderr, "shared-image-codecs-test: TurboJPEG init failed\n");
        return 1;
    }
    tj3Destroy(handle);
    return 0;
}

int main(void) {
    if (test_zlib() != 0 || test_png() != 0 || test_libjpeg() != 0 ||
        test_turbojpeg() != 0) {
        return 1;
    }

    printf("shared-image-codecs-test: zlib=%s libpng=%s turbojpeg=%d PASS\n",
           zlibVersion(), PNG_LIBPNG_VER_STRING, TURBOJPEG_VERSION_NUMBER);
    return 0;
}
