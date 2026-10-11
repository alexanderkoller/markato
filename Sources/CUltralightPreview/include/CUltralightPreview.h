#ifndef C_ULTRALIGHT_PREVIEW_H
#define C_ULTRALIGHT_PREVIEW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AstraULSurface AstraULSurface;

typedef struct {
  double y;
  double height;
  double landmark_y;
  bool has_landmark;
} AstraULGeometryItem;

typedef struct {
  double width;
  double height;
  uint64_t measurement;
  size_t item_count;
} AstraULGeometry;

// Ultralight objects have thread affinity. The caller must create and use all
// surfaces on one serial executor.
AstraULSurface* astra_ul_surface_create(const char* sdk_root, const char* css,
                                        uint32_t width, uint32_t height,
                                        double device_scale);
void astra_ul_surface_destroy(AstraULSurface* surface);
bool astra_ul_surface_ready(AstraULSurface* surface);
void astra_ul_surface_resize(AstraULSurface* surface, uint32_t width,
                             uint32_t height, double device_scale);
// Apply all pending view/DOM/scroll mutations in one renderer update. Returns
// true when this surface produced pixels that should be published.
bool astra_ul_surface_render(AstraULSurface* surface);

void astra_ul_surface_begin_update(AstraULSurface* surface, size_t count,
                                   double font_size);
void astra_ul_surface_add_entry(AstraULSurface* surface, const char* id,
                                const char* html);
bool astra_ul_surface_commit_update(AstraULSurface* surface);
bool astra_ul_surface_patch_entry(AstraULSurface* surface, size_t index,
                                  const char* id, const char* html);

bool astra_ul_surface_geometry(AstraULSurface* surface,
                               AstraULGeometry* geometry);
bool astra_ul_surface_geometry_item(AstraULSurface* surface, size_t index,
                                    AstraULGeometryItem* item);
void astra_ul_surface_scroll(AstraULSurface* surface, double x, double y);

size_t astra_ul_surface_pixel_bytes(AstraULSurface* surface);
bool astra_ul_surface_copy_pixels(AstraULSurface* surface, void* destination,
                                  size_t destination_size,
                                  uint32_t* width, uint32_t* height,
                                  uint32_t* row_bytes);
bool astra_ul_surface_pump(AstraULSurface* surface);

void astra_ul_surface_mouse(AstraULSurface* surface, int type, int x, int y,
                            int button);
void astra_ul_surface_horizontal_scroll(AstraULSurface* surface, int delta_x,
                                        int x, int y);
char* astra_ul_surface_link_at(AstraULSurface* surface, double x, double y);
char* astra_ul_surface_selected_text(AstraULSurface* surface);
char* astra_ul_surface_text(AstraULSurface* surface);
size_t astra_ul_surface_selector_count(AstraULSurface* surface, const char* selector);
bool astra_ul_surface_text_rect(AstraULSurface* surface, const char* selector,
                                const char* containing_text, double* x,
                                double* y, double* width, double* height);
void astra_ul_string_free(char* string);

#ifdef __cplusplus
}
#endif
#endif
