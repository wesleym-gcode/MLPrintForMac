#ifndef CSPL_H
#define CSPL_H

#include <stddef.h>

typedef struct spl_raster spl_raster_t;

/// Opens a CUPS raster stream writing to a file descriptor.
spl_raster_t *spl_raster_open(int fd);

/// Writes one 1-bit (K, 1 = black) page, 600 dpi, to the stream.
/// `bytes_per_line` is ceil(width / 8). `data` has `height * bytes_per_line` bytes.
int spl_raster_write_page(spl_raster_t *r, unsigned width, unsigned height,
                          unsigned bytes_per_line, unsigned dpi,
                          unsigned paper_width_pt, unsigned paper_height_pt,
                          unsigned copies, const unsigned char *data);

void spl_raster_close(spl_raster_t *r);

#endif
