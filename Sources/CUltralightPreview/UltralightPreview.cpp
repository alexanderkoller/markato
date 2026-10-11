#include "CUltralightPreview.h"

#include <AppCore/AppCore.h>
#include <Ultralight/DOM.h>
#include <Ultralight/Ultralight.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

using namespace ultralight;

namespace {

class SilentLogger final : public Logger {
 public:
  void LogMessage(LogLevel, const String&) override {}
};

struct Engine {
  SilentLogger logger;
  RefPtr<Renderer> renderer;

  explicit Engine(const char* root) {
    Config config;
    config.resource_path_prefix = "resources/";
    config.bitmap_alignment = 16;
    Platform::instance().set_config(config);
    Platform::instance().set_font_loader(GetPlatformFontLoader());
    Platform::instance().set_file_system(GetPlatformFileSystem(root));
    Platform::instance().set_logger(&logger);
    renderer = Renderer::Create();
  }

  void render() {
    renderer->Update();
    renderer->RefreshDisplay(0);
    renderer->Render();
  }
};

std::unique_ptr<Engine> engine;

struct Entry {
  std::string id;
  std::string html;
  dom::Element element;
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
  RefPtr<View> view;
  dom::Triggers triggers;
  dom::Document document;
  dom::Element root;
  bool ready = false;
  uint64_t measurement = 0;
  std::vector<Entry> entries;
  std::vector<std::pair<std::string, std::string>> pending;
  double pending_font_size = 14;

  AstraULSurface(const char* css, uint32_t width, uint32_t height,
                 double device_scale) {
    ViewConfig config;
    config.initial_device_scale = device_scale;
    config.is_accelerated = false;
    config.enable_javascript = false;
    view = engine->renderer->CreateView(std::max(1u, width), std::max(1u, height),
                                        config, nullptr);
    triggers.OnDOMReady([this](dom::Document value) {
      document = value;
      root = document.getElementById("preview");
      ready = !!root;
    });
    if (!triggers.AttachTo(view.get())) return;
    std::string shell = "<!doctype html><html><head><meta charset='utf-8'><style>";
    shell += css ? css : "";
    shell += "</style></head><body><main id='preview'></main></body></html>";
    view->LoadHTML(shell.c_str());
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
      auto found = old.find(item.first);
      if (found != old.end()) {
        Entry retained = entries[found->second];
        if (retained.html != item.second) {
          retained.element.innerHTML = item.second;
          retained.html = item.second;
        }
        next.push_back(std::move(retained));
      } else {
        std::string section = "<section data-id='" + attribute_escape(item.first) + "'>" +
                              item.second + "</section>";
        root.insertAdjacentHTML("beforeend", section);
        auto element = root.lastElementChild();
        next.push_back(Entry{item.first, item.second, element});
      }
    }
    for (auto& previous : entries) {
      if (std::none_of(next.begin(), next.end(), [&](const Entry& value) {
            return value.id == previous.id;
          })) previous.element.remove();
    }
    dom::Element cursor = root.firstElementChild();
    for (auto& entry : next) {
      if (!cursor || !cursor.IsSame(entry.element)) root.insertBefore(entry.element, cursor);
      cursor = entry.element.nextElementSibling();
    }
    if (!next.empty()) next.back().element.setAttribute("class", "last-block");
    if (!entries.empty() && (next.empty() || !entries.back().element.IsSame(next.back().element)))
      entries.back().element.removeAttribute("class");
    entries = std::move(next);
    pending.clear();
    auto html = document.documentElement();
    html.setAttribute("style", "font-size:" + std::to_string(pending_font_size) + "px");
    render();
    ++measurement;
    return true;
  }
};

extern "C" {

AstraULSurface* astra_ul_surface_create(const char* sdk_root, const char* css,
                                        uint32_t width, uint32_t height,
                                        double device_scale) {
  if (!engine) engine = std::make_unique<Engine>(sdk_root);
  auto* result = new AstraULSurface(css, width, height, device_scale);
  return result->ready ? result : (delete result, nullptr);
}

void astra_ul_surface_destroy(AstraULSurface* surface) { delete surface; }
bool astra_ul_surface_ready(AstraULSurface* surface) { return surface && surface->ready; }

void astra_ul_surface_resize(AstraULSurface* surface, uint32_t width,
                             uint32_t height, double device_scale) {
  if (!surface) return;
  surface->view->Resize(std::max(1u, width), std::max(1u, height), device_scale);
  ++surface->measurement;
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
                                const char* html) {
  if (surface) surface->pending.emplace_back(id ? id : "", html ? html : "");
}

bool astra_ul_surface_commit_update(AstraULSurface* surface) {
  return surface && surface->commit();
}

bool astra_ul_surface_patch_entry(AstraULSurface* surface, size_t index,
                                  const char* id, const char* html) {
  if (!surface || index >= surface->entries.size() ||
      surface->entries[index].id != (id ? id : "")) return false;
  auto& entry = surface->entries[index];
  entry.html = html ? html : "";
  entry.element.innerHTML = entry.html;
  surface->render();
  ++surface->measurement;
  return true;
}

bool astra_ul_surface_geometry(AstraULSurface* surface,
                               AstraULGeometry* geometry) {
  if (!surface || !geometry || !surface->ready) return false;
  auto rect = surface->root.getBoundingClientRect();
  geometry->width = rect.width;
  geometry->height = surface->root.offsetHeight();
  geometry->measurement = surface->measurement;
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
  if (landmark) item->landmark_y = landmark.getBoundingClientRect().y - root_rect.y;
  return true;
}

void astra_ul_surface_scroll(AstraULSurface* surface, double x, double y) {
  if (!surface) return;
  surface->document.defaultView().scrollTo(x, y);
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

char* astra_ul_surface_link_at(AstraULSurface* surface, double x, double y) {
  if (!surface) return nullptr;
  auto element = surface->document.elementFromPoint(x, y).closest("a[href]");
  if (!element) return nullptr;
  auto href = element.getAttribute("href");
  return href ? copy_string(*href) : nullptr;
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
