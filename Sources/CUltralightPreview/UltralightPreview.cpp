#include "CUltralightPreview.h"

#include <AppCore/AppCore.h>
#include <Ultralight/DOM.h>
#include <Ultralight/Ultralight.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace ultralight;

namespace {

class SilentLogger final : public Logger {
 public:
  void LogMessage(LogLevel, const String&) override {}
};
SilentLogger logger;
std::once_flag platform_once;
std::string platform_resource_path;
std::mutex& renderer_lifecycle_mutex() {
  // The renderer worker is process-lifetime. Keep its lifecycle lock alive for
  // the same duration instead of racing C++ static destruction at application exit.
  static auto* value = new std::mutex;
  return *value;
}

struct Engine {
  RefPtr<Renderer> renderer;

  explicit Engine(const char* root) {
    std::string sdk_root = root ? root : "";
    while (!sdk_root.empty() && sdk_root.front() == '/') sdk_root.erase(sdk_root.begin());
    std::call_once(platform_once, [&] {
      Config config;
      platform_resource_path = sdk_root + "/resources/";
      config.resource_path_prefix = platform_resource_path.c_str();
      config.bitmap_alignment = 16;
      // The platform loader supplies macOS system font files, while this profile
      // makes Ultralight composite their glyphs like Safari and other macOS apps.
      // Ultralight's default profile is WindowsLike, even on macOS.
      config.font_profile = FontProfile::MacOSLike;
      Platform::instance().set_config(config);
      Platform::instance().set_font_loader(GetPlatformFontLoader());
      // The stock platform file system maps file:/// paths relative to its base.
      // Rooting it at / lets preview HTML use the document's actual absolute file
      // URLs while the resource prefix above still locates the Ultralight SDK.
      Platform::instance().set_file_system(GetPlatformFileSystem("/"));
      Platform::instance().set_logger(&logger);
    });
    std::lock_guard<std::mutex> lock(renderer_lifecycle_mutex());
    renderer = Renderer::Create();
  }

  ~Engine() {
    std::lock_guard<std::mutex> lock(renderer_lifecycle_mutex());
    renderer = nullptr;
  }

  void render() {
    renderer->Update();
    renderer->RefreshDisplay(0);
    renderer->Render();
  }
};

struct Entry {
  std::string id;
  std::string html;
  dom::Element element;
  bool document_first = false;
};

struct PendingEntry {
  std::string id;
  std::string html;
  bool document_first = false;
};

static char* copy_string(const std::string& value) {
  auto* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}

static std::string attribute_escape(const std::string& value) {
  std::string result;
  result.reserve(value.size());
  for (char c : value) {
    if (c == '&') result += "&amp;";
    else if (c == '\'') result += "&#39;";
    else if (c == '<') result += "&lt;";
    else if (c == '>') result += "&gt;";
    else result += c;
  }
  return result;
}

}  // namespace

struct AstraULSurface {
  std::unique_ptr<Engine> engine;
  RefPtr<View> view;
  dom::Triggers triggers;
  dom::Document document;
  dom::Element root;
  bool ready = false;
  std::vector<Entry> entries;
  std::vector<PendingEntry> pending;
  struct PendingImage {
    std::string owner;
    dom::Element element;
  };
  std::vector<PendingImage> pending_images;
  std::vector<PendingImage> delayed_images;
  std::unordered_set<std::string> dirty_entries;
  double pending_font_size = 14;
  dom::Node resize_anchor_node;
  size_t resize_anchor_offset = 0;
  double resize_anchor_target_viewport_y = 0;
  bool has_resize_anchor = false;

  size_t text_length(const dom::Node& node) const {
    const std::string text = node.nodeValue;
    return String(text.c_str(), text.size()).utf16().length();
  }

  bool capture_text_anchor(const dom::Node& node) {
    // KaTeX places its clipped, 1x1 accessibility MathML tree before the
    // painted HTML tree. Its text has a DOM rectangle, but that rectangle is
    // not the glyph position users see and does not reflow like the painted
    // formula. A visual resize anchor must therefore come from katex-html.
    if (node.nodeType() == dom::NodeType::Element &&
        node.AsElement().matches(".katex-mathml")) return false;
    if (node.nodeType() == dom::NodeType::Text) {
      const size_t length = text_length(node);
      if (length == 0) return false;
      auto range = document.createRange();
      range.setStart(node, 0);
      range.setEnd(node, length);
      const auto whole = range.getBoundingClientRect();
      if (whole.width <= 0 || whole.height <= 0 || whole.bottom() <= 0) return false;
      // Character rectangles are vertically monotonic within a text node.
      // Locate the first visible character without scanning a potentially
      // very large paragraph one UTF-16 unit at a time.
      size_t low = 0, high = length;
      while (low < high) {
        const size_t middle = low + (high - low) / 2;
        range.setStart(node, middle);
        range.setEnd(node, middle + 1);
        if (range.getBoundingClientRect().bottom() > 0) high = middle;
        else low = middle + 1;
      }
      while (low < length) {
        range.setStart(node, low);
        range.setEnd(node, low + 1);
        const auto candidate = range.getBoundingClientRect();
        if (candidate.height > 0 && candidate.width > 0 && candidate.bottom() > 0) break;
        ++low;
      }
      if (low >= length) return false;
      range.setStart(node, low);
      range.setEnd(node, low + 1);
      const auto rect = range.getBoundingClientRect();
      resize_anchor_node = node;
      resize_anchor_offset = low;
      resize_anchor_target_viewport_y = rect.y;
      has_resize_anchor = true;
      return true;
    }
    for (auto child = node.firstChild(); child; child = child.nextSibling())
      if (capture_text_anchor(child)) return true;
    return false;
  }

  bool capture_resize_anchor() {
    has_resize_anchor = false;
    for (const auto& entry : entries) {
      const auto rect = entry.element.getBoundingClientRect();
      if (rect.bottom() <= 0) continue;
      if (capture_text_anchor(entry.element)) return true;
    }
    return false;
  }

  bool resize_anchor_scroll_y(double* value) {
    if (!has_resize_anchor || !resize_anchor_node.isConnected()) return false;
    const size_t length = text_length(resize_anchor_node);
    if (resize_anchor_offset >= length) return false;
    auto range = document.createRange();
    range.setStart(resize_anchor_node, resize_anchor_offset);
    range.setEnd(resize_anchor_node, resize_anchor_offset + 1);
    const auto rect = range.getBoundingClientRect();
    if (rect.height <= 0 || rect.width <= 0) return false;
    if (value) *value = std::max(0.0, document.defaultView().scrollY()
        + rect.y - resize_anchor_target_viewport_y);
    return true;
  }

  bool resize_anchor_viewport_y(double* value) {
    if (!has_resize_anchor || !resize_anchor_node.isConnected()) return false;
    const size_t length = text_length(resize_anchor_node);
    if (resize_anchor_offset >= length) return false;
    auto range = document.createRange();
    range.setStart(resize_anchor_node, resize_anchor_offset);
    range.setEnd(resize_anchor_node, resize_anchor_offset + 1);
    const auto rect = range.getBoundingClientRect();
    if (rect.height <= 0 || rect.width <= 0) return false;
    if (value) *value = rect.y;
    return true;
  }

  std::string owner_of(dom::Element element) const {
    for (auto current = element; current; current = current.parentElement()) {
      for (const auto& entry : entries)
        if (current.IsSame(entry.element)) return entry.id;
    }
    return {};
  }

  void resource_finished(dom::Element image) {
    const auto pending = std::find_if(
        pending_images.begin(), pending_images.end(),
        [&](const PendingImage& value) { return value.element.IsSame(image); });
    if (pending == pending_images.end()) return;
    const std::string owner = owner_of(image);
    if (!owner.empty()) dirty_entries.insert(owner);
    pending_images.erase(
        std::remove_if(pending_images.begin(), pending_images.end(),
                       [&](const PendingImage& value) { return value.element.IsSame(image); }),
        pending_images.end());
  }

  void layout_event(dom::Element element) {
    const std::string owner = owner_of(element);
    if (!owner.empty()) dirty_entries.insert(owner);
  }

  void sanitize(Entry& entry) {
    auto forbidden = entry.element.querySelectorAll("style,link[rel~='stylesheet'],base");
    for (auto element : forbidden) element.remove();
  }

  void track_images(Entry& entry) {
    pending_images.erase(
        std::remove_if(pending_images.begin(), pending_images.end(),
                       [&](const PendingImage& value) { return value.owner == entry.id; }),
        pending_images.end());
    delayed_images.erase(
        std::remove_if(delayed_images.begin(), delayed_images.end(),
                       [&](const PendingImage& value) { return value.owner == entry.id; }),
        delayed_images.end());
    for (auto image : entry.element.querySelectorAll("img")) {
      if (image.hasAttribute("data-astra-delayed-src"))
        delayed_images.push_back(PendingImage{entry.id, image});
      else
        pending_images.push_back(PendingImage{entry.id, image});
    }
  }

  void activate_delayed_images() {
    auto delayed = std::move(delayed_images);
    delayed_images.clear();
    for (const auto& image : delayed) {
      auto source = image.element.getAttribute("data-astra-delayed-src");
      if (!source) continue;
      pending_images.push_back(image);
      image.element.removeAttribute("data-astra-delayed-src");
      image.element.setAttribute("src", *source);
    }
  }

  AstraULSurface(const char* css, uint32_t width, uint32_t height,
                 double device_scale, const char* sdk_root)
      : engine(std::make_unique<Engine>(sdk_root)) {
    ViewConfig config;
    config.initial_device_scale = device_scale;
    config.is_accelerated = false;
    config.enable_javascript = false;
    view = engine->renderer->CreateView(std::max(1u, width), std::max(1u, height),
                                        config, nullptr);
    triggers.On("img", "load", [this](dom::Element image) { resource_finished(image); },
                dom::Capture);
    triggers.On("img", "error", [this](dom::Element image) { resource_finished(image); },
                dom::Capture);
    triggers.On("details", "toggle", [this](dom::Element details) { layout_event(details); },
                dom::Capture);
    triggers.OnDOMReady([this](dom::Document value) {
      document = value;
      root = document.getElementById("preview");
      ready = !!root;
    });
    if (!triggers.AttachTo(view.get())) return;
    std::string shell = "<!doctype html><html><head><meta charset='utf-8'><style>";
    shell += css ? css : "";
    shell += "</style></head><body><main id='preview'></main></body></html>";
    // Give application-supplied HTML a local origin. An opaque LoadHTML origin
    // cannot fetch file:/// images even when the stock file system can resolve
    // their absolute paths.
    view->LoadHTML(shell.c_str(), "file:///astra-preview.html");
    for (int attempt = 0; attempt < 10000 && !ready; ++attempt) engine->render();
  }

  void render() { engine->render(); }

  bool commit() {
    if (!ready) return false;
    std::unordered_map<std::string, size_t> old;
    for (size_t i = 0; i < entries.size(); ++i) old.emplace(entries[i].id, i);
    std::vector<Entry> next;
    next.reserve(pending.size());
    for (const auto& item : pending) {
      auto found = old.find(item.id);
      if (found != old.end()) {
        Entry retained = entries[found->second];
        if (retained.html != item.html) {
          retained.element.innerHTML = item.html;
          retained.html = item.html;
          sanitize(retained);
          track_images(retained);
        }
        retained.document_first = item.document_first;
        retained.element.setAttribute("class", item.document_first
            ? "astra-preview-block document-first" : "astra-preview-block");
        next.push_back(std::move(retained));
      } else {
        std::string section = "<section class='astra-preview-block";
        if (item.document_first) section += " document-first";
        section += "' data-id='" + attribute_escape(item.id) + "'>" + item.html + "</section>";
        root.insertAdjacentHTML("beforeend", section);
        auto element = root.lastElementChild();
        next.push_back(Entry{item.id, item.html, element, item.document_first});
        sanitize(next.back());
        track_images(next.back());
      }
    }
    for (auto& previous : entries) {
      if (std::none_of(next.begin(), next.end(), [&](const Entry& value) {
            return value.id == previous.id;
          })) previous.element.remove();
    }
    pending_images.erase(
        std::remove_if(pending_images.begin(), pending_images.end(), [&](const PendingImage& image) {
          return std::none_of(next.begin(), next.end(),
                              [&](const Entry& value) { return value.id == image.owner; });
        }),
        pending_images.end());
    delayed_images.erase(
        std::remove_if(delayed_images.begin(), delayed_images.end(), [&](const PendingImage& image) {
          return std::none_of(next.begin(), next.end(),
                              [&](const Entry& value) { return value.id == image.owner; });
        }),
        delayed_images.end());
    dom::Element cursor = root.firstElementChild();
    for (auto& entry : next) {
      if (!cursor || !cursor.IsSame(entry.element)) root.insertBefore(entry.element, cursor);
      cursor = entry.element.nextElementSibling();
    }
    entries = std::move(next);
    pending.clear();
    auto html = document.documentElement();
    html.setAttribute("style", "font-size:" + std::to_string(pending_font_size) + "px");
    // Advance style and layout so callers can measure the committed DOM.
    // The visible surface forces exactly one full paint immediately before it
    // captures this revision; measurement-only surfaces need no bitmap.
    render();
    return true;
  }
};

extern "C" {

AstraULSurface* astra_ul_surface_create(const char* sdk_root, const char* css,
                                        uint32_t width, uint32_t height,
                                        double device_scale) {
  auto* result = new AstraULSurface(css, width, height, device_scale, sdk_root);
  return result->ready ? result : (delete result, nullptr);
}

void astra_ul_surface_destroy(AstraULSurface* surface) { delete surface; }
void astra_ul_surface_resize(AstraULSurface* surface, uint32_t width,
                             uint32_t height, double device_scale) {
  if (!surface) return;
  surface->view->Resize(std::max(1u, width), std::max(1u, height), device_scale);
}

bool astra_ul_surface_render(AstraULSurface* surface) {
  if (!surface) return false;
  surface->render();
  auto* pixels = surface->view->surface();
  return pixels && !pixels->dirty_bounds().IsEmpty();
}

void astra_ul_surface_begin_update(AstraULSurface* surface, size_t count,
                                   double font_size) {
  if (!surface) return;
  surface->pending.clear();
  surface->pending.reserve(count);
  surface->pending_font_size = font_size;
}

void astra_ul_surface_add_entry(AstraULSurface* surface, const char* id,
                                const char* html, bool document_first) {
  if (surface) surface->pending.push_back(
      PendingEntry{id ? id : "", html ? html : "", document_first});
}

bool astra_ul_surface_commit_update(AstraULSurface* surface) {
  return surface && surface->commit();
}

bool astra_ul_surface_geometry(AstraULSurface* surface,
                               AstraULGeometry* geometry) {
  if (!surface || !geometry || !surface->ready) return false;
  auto rect = surface->root.getBoundingClientRect();
  geometry->width = rect.width;
  geometry->height = surface->root.offsetHeight();
  geometry->item_count = surface->entries.size();
  return true;
}

bool astra_ul_surface_geometry_item(AstraULSurface* surface, size_t index,
                                    AstraULGeometryItem* item) {
  if (!surface || !item || index >= surface->entries.size()) return false;
  auto root_rect = surface->root.getBoundingClientRect();
  auto rect = surface->entries[index].element.getBoundingClientRect();
  item->y = rect.y - root_rect.y;
  item->height = rect.height;
  auto landmark = surface->entries[index].element.querySelector("h1,h2,h3,h4,h5,h6,p > img:only-child");
  item->has_landmark = !!landmark;
  item->landmark_y = 0;
  if (landmark) item->landmark_y = landmark.getBoundingClientRect().y - rect.y;
  return true;
}

size_t astra_ul_surface_dirty_count(AstraULSurface* surface) {
  return surface ? surface->dirty_entries.size() : 0;
}

char* astra_ul_surface_take_dirty_id(AstraULSurface* surface) {
  if (!surface || surface->dirty_entries.empty()) return nullptr;
  auto item = surface->dirty_entries.begin();
  std::string id = *item;
  surface->dirty_entries.erase(item);
  return copy_string(id);
}

size_t astra_ul_surface_pending_resource_count(AstraULSurface* surface) {
  return surface ? surface->pending_images.size() + surface->delayed_images.size() : 0;
}

void astra_ul_surface_activate_delayed_images(AstraULSurface* surface) {
  if (surface) surface->activate_delayed_images();
}

void astra_ul_surface_abandon_pending_resources(AstraULSurface* surface) {
  if (!surface) return;
  surface->pending_images.clear();
  surface->delayed_images.clear();
}

bool astra_ul_surface_scroll(AstraULSurface* surface, double x, double y) {
  if (!surface) return false;
  auto window = surface->document.defaultView();
  const double old_x = window.scrollX();
  const double old_y = window.scrollY();
  window.scrollTo(x, y);
  if (std::abs(window.scrollX() - old_x) < 0.01 &&
      std::abs(window.scrollY() - old_y) < 0.01) return false;
  // Renderer::Render applies viewport scrolling through Surface::Scroll,
  // shifting the existing pixels and painting only the exposed strip. Do not
  // force a general repaint here: ordinary scrolling is not a layout change.
  return true;
}

double astra_ul_surface_scroll_y(AstraULSurface* surface) {
  if (!surface) return 0;
  return surface->document.defaultView().scrollY();
}

bool astra_ul_surface_capture_resize_anchor(AstraULSurface* surface) {
  return surface && surface->capture_resize_anchor();
}

bool astra_ul_surface_resize_anchor_scroll_y(AstraULSurface* surface,
                                             double* scroll_y) {
  return surface && surface->resize_anchor_scroll_y(scroll_y);
}

bool astra_ul_surface_resize_anchor_viewport_y(AstraULSurface* surface,
                                               double* viewport_y) {
  return surface && surface->resize_anchor_viewport_y(viewport_y);
}

bool astra_ul_surface_resize_anchor_target_viewport_y(AstraULSurface* surface,
                                                      double* viewport_y) {
  if (!surface || !surface->has_resize_anchor) return false;
  if (viewport_y) *viewport_y = surface->resize_anchor_target_viewport_y;
  return true;
}

void astra_ul_surface_clear_resize_anchor(AstraULSurface* surface) {
  if (!surface) return;
  surface->has_resize_anchor = false;
  surface->resize_anchor_node = {};
}

void astra_ul_surface_invalidate(AstraULSurface* surface) {
  if (surface) surface->view->set_needs_paint(true);
}

void astra_ul_surface_clear_dirty_pixels(AstraULSurface* surface) {
  if (!surface) return;
  auto* pixels = surface->view->surface();
  if (pixels) pixels->ClearDirtyBounds();
}

size_t astra_ul_surface_pixel_bytes(AstraULSurface* surface) {
  if (!surface || !surface->view->surface()) return 0;
  auto* pixels = surface->view->surface();
  return static_cast<size_t>(pixels->row_bytes()) * pixels->height();
}

bool astra_ul_surface_copy_pixels(AstraULSurface* surface, void* destination,
                                  size_t destination_size, uint32_t* width,
                                  uint32_t* height, uint32_t* row_bytes) {
  if (!surface || !destination) return false;
  auto* pixels = surface->view->surface();
  if (!pixels) return false;
  const size_t bytes = static_cast<size_t>(pixels->row_bytes()) * pixels->height();
  if (destination_size < bytes) return false;
  void* source = pixels->LockPixels();
  if (!source) return false;
  std::memcpy(destination, source, bytes);
  pixels->UnlockPixels();
  pixels->ClearDirtyBounds();
  if (width) *width = pixels->width();
  if (height) *height = pixels->height();
  if (row_bytes) *row_bytes = pixels->row_bytes();
  return true;
}

bool astra_ul_surface_pump(AstraULSurface* surface) {
  if (!surface) return false;
  surface->render();
  auto* pixels = surface->view->surface();
  return pixels && !pixels->dirty_bounds().IsEmpty();
}

void astra_ul_surface_mouse(AstraULSurface* surface, int type, int x, int y,
                            int button) {
  if (!surface) return;
  MouseEvent event;
  event.type = static_cast<MouseEvent::Type>(std::clamp(type, 0, 2));
  event.x = x; event.y = y;
  event.button = static_cast<MouseEvent::Button>(std::clamp(button, 0, 5));
  surface->view->FireMouseEvent(event);
  surface->render();
}

void astra_ul_surface_horizontal_scroll(AstraULSurface* surface, int delta_x,
                                        int x, int y) {
  if (!surface) return;
  ScrollEvent event;
  event.type = ScrollEvent::kType_ScrollByPixel;
  event.delta_x = delta_x; event.delta_y = 0; event.x = x; event.y = y;
  surface->view->FireScrollEvent(event);
  surface->render();
}

bool astra_ul_surface_toggle_first_details(AstraULSurface* surface) {
  if (!surface) return false;
  auto details = surface->root.querySelector("details");
  if (!details) return false;
  if (details.hasAttribute("open")) details.removeAttribute("open");
  else details.setAttribute("open", "");
  surface->layout_event(details);
  surface->render();
  return true;
}

char* astra_ul_surface_link_at(AstraULSurface* surface, double x, double y) {
  if (!surface) return nullptr;
  auto element = surface->document.elementFromPoint(x, y).closest("a[href]");
  if (!element) return nullptr;
  auto href = element.getAttribute("href");
  return href ? copy_string(*href) : nullptr;
}

bool astra_ul_surface_link_rect_at(AstraULSurface* surface, double x, double y,
                                   double* rect_x, double* rect_y,
                                   double* width, double* height) {
  if (!surface) return false;
  auto element = surface->document.elementFromPoint(x, y).closest("a[href]");
  if (!element) return false;
  auto rect = element.getBoundingClientRect();
  if (rect_x) *rect_x = rect.x;
  if (rect_y) *rect_y = rect.y;
  if (width) *width = rect.width;
  if (height) *height = rect.height;
  return true;
}

char* astra_ul_surface_selected_text(AstraULSurface* surface) {
  if (!surface) return nullptr;
  return copy_string(surface->document.getSelection().toString());
}

char* astra_ul_surface_text(AstraULSurface* surface) {
  if (!surface || !surface->ready) return nullptr;
  return copy_string(static_cast<std::string>(surface->root.innerText));
}

size_t astra_ul_surface_selector_count(AstraULSurface* surface, const char* selector) {
  if (!surface || !surface->ready || !selector) return 0;
  return surface->root.querySelectorAll(selector).length();
}

bool astra_ul_surface_text_rect(AstraULSurface* surface, const char* selector,
                                const char* containing_text, double* x,
                                double* y, double* width, double* height) {
  if (!surface || !surface->ready || !selector) return false;
  const std::string needle = containing_text ? containing_text : "";
  auto elements = surface->root.querySelectorAll(selector);
  for (size_t index = 0; index < elements.length(); ++index) {
    auto element = elements.item(index).AsElement();
    if (!needle.empty() && static_cast<std::string>(element.textContent).find(needle) == std::string::npos) continue;
    auto rect = element.getBoundingClientRect();
    if (x) *x = rect.x; if (y) *y = rect.y;
    if (width) *width = rect.width; if (height) *height = rect.height;
    return true;
  }
  return false;
}

void astra_ul_string_free(char* string) { std::free(string); }

}  // extern "C"
