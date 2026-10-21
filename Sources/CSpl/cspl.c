#include "cspl.h"

#include <cups/raster.h>
#include <string.h>

struct spl_raster {
    cups_raster_t *raster;
};

static spl_raster_t handle_storage[1];

spl_raster_t *spl_raster_open(int fd) {
    cups_raster_t *raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE);
    if (!raster)
        return NULL;
    handle_storage[0].raster = raster;
    return &handle_storage[0];
}

int spl_raster_write_page(spl_raster_t *r, unsigned width, unsigned height,
                          unsigned bytes_per_line, unsigned dpi,
                          unsigned paper_width_pt, unsigned paper_height_pt,
                          unsigned copies, const unsigned char *data) {
    cups_page_header2_t header;
    memset(&header, 0, sizeof(header));

    header.HWResolution[0] = dpi;
    header.HWResolution[1] = dpi;
    header.PageSize[0] = paper_width_pt;
    header.PageSize[1] = paper_height_pt;
    header.cupsPageSize[0] = (float)paper_width_pt;
    header.cupsPageSize[1] = (float)paper_height_pt;
    header.Margins[0] = 10;
    header.Margins[1] = 15;
    header.NumCopies = copies;
    header.cupsWidth = width;
    header.cupsHeight = height;
    header.cupsBitsPerColor = 1;
    header.cupsBitsPerPixel = 1;
    header.cupsBytesPerLine = bytes_per_line;
    header.cupsColorOrder = CUPS_ORDER_CHUNKED;
    header.cupsColorSpace = CUPS_CSPACE_K;
    header.cupsCompression = 17;
    header.cupsNumColors = 1;
    header.cupsInteger[0] = 1;

    if (!cupsRasterWriteHeader2(r->raster, &header))
        return 0;

    for (unsigned y = 0; y < height; y++) {
        if (cupsRasterWritePixels(r->raster, (unsigned char *)(data + (size_t)y * bytes_per_line),
                                  bytes_per_line) != bytes_per_line)
            return 0;
    }
    return 1;
}

void spl_raster_close(spl_raster_t *r) {
    if (r && r->raster)
        cupsRasterClose(r->raster);
}
