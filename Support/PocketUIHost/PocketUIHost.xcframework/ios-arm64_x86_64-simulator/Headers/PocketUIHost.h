#ifndef POCKET_UI_HOST_H
#define POCKET_UI_HOST_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#define PDUI_NOEXCEPT noexcept
#else
#define PDUI_NOEXCEPT
#endif

typedef struct pdui_context pdui_context;
enum {
  PDUI_OK = 0,
  PDUI_INVALID_ARGUMENT = 1,
  PDUI_INVALID_FONT = 2,
  PDUI_INVALID_CARD = 3,
  PDUI_INVALID_IMAGE = 4,
  PDUI_RENDER_FAILED = 5,
  PDUI_NO_FRAME = 6,
  PDUI_BUFFER_TOO_SMALL = 7,
  PDUI_OUT_OF_MEMORY = 8,
  PDUI_INTERNAL_ERROR = 9
};
// Version 1 content-page API. Physical width must be byte-aligned, dimensions
// 1..2048; orientation: 0 portrait, 1 clockwise, 2 inverted, 3 counterclockwise.
// Font bytes (1..64MiB cpfont v4) are copied on create. Contexts are independent;
// serialize ALL calls (including destroy) on a single context. No OS/network I/O.
// Concurrent calls on different contexts are allowed, but rasterization is
// internally serialized because the production bidi engine shares scratch.
uint32_t pdui_abi_version(void) PDUI_NOEXCEPT;
int32_t pdui_create(uint32_t physical_width, uint32_t physical_height, uint32_t orientation, const uint8_t* font,
                    size_t font_size, pdui_context** output) PDUI_NOEXCEPT;
void pdui_destroy(pdui_context* context) PDUI_NOEXCEPT;

// Fixed-size, NUL-terminated UTF-8 chrome strings supplied by the app's locale.
// No controls or malformed UTF-8. Zero-initialize this structure before filling.
typedef struct {
  int32_t side_padding, top_padding, spacing;
  char empty_title[64];
  char empty_message[192];
  char labels[4][64];
} pdui_content_options;
// card=NULL,size=0 renders the empty state; otherwise the exact512-byte PDCT
// document is validated by the production decoder. Image bytes are the PBM
// referenced by that one card (max32784 bytes); no path is opened. Arguments
// are borrowed only for this synchronous call. Every attempt invalidates the
// previous frame, including invalid arguments; only full success exposes pixels.
int32_t pdui_render_content(pdui_context* context, const uint8_t* card, size_t card_size, const uint8_t* image,
                            size_t image_size, const pdui_content_options* options) PDUI_NOEXCEPT;

// Native physical framebuffer: top-to-bottom rows, MSB-first bits, 0 black and
// 1 white. Orientation describes logical-to-physical mapping, not BMP metadata.
typedef struct {
  uint32_t physical_width, physical_height, row_bytes, byte_count;
  uint32_t logical_width, logical_height, orientation;
} pdui_frame_info;
int32_t pdui_get_frame_info(const pdui_context* context, pdui_frame_info* output) PDUI_NOEXCEPT;
// Copies a successful frame into caller-owned memory. Errors leave it unchanged.
int32_t pdui_copy_frame(const pdui_context* context, uint8_t* output, size_t capacity) PDUI_NOEXCEPT;
#ifdef __cplusplus
}
#endif
#undef PDUI_NOEXCEPT
#endif
