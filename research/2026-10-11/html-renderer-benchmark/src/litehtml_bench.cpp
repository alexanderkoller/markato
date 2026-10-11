#include <litehtml.h>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/resource.h>

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::milli>(b - a).count();
}

class NullContainer final : public litehtml::document_container {
 public:
  std::uint64_t paint_ops = 0;
  litehtml::uint_ptr create_font(const litehtml::font_description& d,
      const litehtml::document*, litehtml::font_metrics* m) override {
    int size = std::max(1, static_cast<int>(d.size));
    if (m) {
      m->font_size = size; m->height = static_cast<int>(std::ceil(size * 1.2));
      m->ascent = static_cast<int>(std::ceil(size * .9));
      m->descent = m->height - m->ascent; m->x_height = static_cast<int>(size * .5);
      m->ch_width = static_cast<int>(size * .55); m->sub_shift = 0; m->super_shift = 0;
    }
    return static_cast<litehtml::uint_ptr>(size);
  }
  void delete_font(litehtml::uint_ptr) override {}
  litehtml::pixel_t text_width(const char* s, litehtml::uint_ptr f) override {
    return static_cast<int>(std::ceil(std::char_traits<char>::length(s) * f * .52));
  }
  void draw_text(litehtml::uint_ptr, const char*, litehtml::uint_ptr,
                 litehtml::web_color, const litehtml::position&) override { ++paint_ops; }
  litehtml::pixel_t pt_to_px(float pt) const override { return static_cast<int>(pt * 96 / 72); }
  litehtml::pixel_t get_default_font_size() const override { return 14; }
  const char* get_default_font_name() const override { return "sans-serif"; }
  void draw_list_marker(litehtml::uint_ptr, const litehtml::list_marker&) override { ++paint_ops; }
  void load_image(const char*, const char*, bool) override {}
  void get_image_size(const char*, const char*, litehtml::size& s) override { s.width=0; s.height=0; }
  void draw_image(litehtml::uint_ptr, const litehtml::background_layer&, const std::string&, const std::string&) override { ++paint_ops; }
  void draw_solid_fill(litehtml::uint_ptr, const litehtml::background_layer&, const litehtml::web_color&) override { ++paint_ops; }
  void draw_linear_gradient(litehtml::uint_ptr, const litehtml::background_layer&, const litehtml::background_layer::linear_gradient&) override { ++paint_ops; }
  void draw_radial_gradient(litehtml::uint_ptr, const litehtml::background_layer&, const litehtml::background_layer::radial_gradient&) override { ++paint_ops; }
  void draw_conic_gradient(litehtml::uint_ptr, const litehtml::background_layer&, const litehtml::background_layer::conic_gradient&) override { ++paint_ops; }
  void draw_borders(litehtml::uint_ptr, const litehtml::borders&, const litehtml::position&, bool) override { ++paint_ops; }
  void set_caption(const char*) override {}
  void set_base_url(const char*) override {}
  void link(const litehtml::document::ptr&, const litehtml::element::ptr&) override {}
  void on_anchor_click(const char*, const litehtml::element::ptr&) override {}
  void on_mouse_event(const litehtml::element::ptr&, litehtml::mouse_event) override {}
  void set_cursor(const char*) override {}
  void transform_text(std::string&, litehtml::text_transform) override {}
  void import_css(std::string& text, const std::string&, std::string&) override { text.clear(); }
  void set_clip(const litehtml::position&, const litehtml::border_radiuses&) override {}
  void del_clip() override {}
  void get_viewport(litehtml::position& p) const override { p = litehtml::position(0,0,560,760); }
  litehtml::element::ptr create_element(const char*, const litehtml::string_map&,
      const litehtml::document::ptr&) override { return nullptr; }
  void get_media_features(litehtml::media_features& m) const override {
    m.type=litehtml::media_type_screen; m.width=560; m.height=760;
    m.device_width=560; m.device_height=760; m.color=8; m.resolution=96;
  }
  void get_language(std::string& language, std::string& culture) const override {
    language="en"; culture="en-US";
  }
};

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  std::ifstream in(argv[1], std::ios::binary);
  std::ostringstream buffer; buffer << in.rdbuf();
  std::string html = buffer.str();
  NullContainer container;
  auto t0=Clock::now();
  auto doc=litehtml::document::createFromString(html.c_str(), &container);
  auto t1=Clock::now();
  doc->render(560);
  auto t2=Clock::now();
  int height=static_cast<int>(doc->height());
  auto mid_marker=doc->root()->select_one("#mid-target");
  auto end_marker=doc->root()->select_one("#end-target");
  if (!mid_marker || !end_marker) return 4;
  auto mid_pos=mid_marker->get_placement();
  auto end_pos=end_marker->get_placement();
  double draws[3]{}; std::uint64_t ops[3]{};
  for (int i=0;i<3;i++) {
    int y = i==0 ? 0 : (i==1 ? std::max(0,(height-760)/2) : std::max(0,height-760));
    // Current litehtml compares translated (screen-relative) boxes against the
    // clip during draw, despite older documentation calling the clip document-relative.
    litehtml::position clip(0,0,560,760);
    container.paint_ops=0; auto a=Clock::now();
    doc->draw(0,0,-y,&clip);
    auto b=Clock::now(); draws[i]=ms(a,b); ops[i]=container.paint_ops;
  }
  struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
  std::cout << "{\"engine\":\"litehtml\",\"html_bytes\":" << html.size()
    << ",\"parse_style_ms\":" << ms(t0,t1) << ",\"layout_ms\":" << ms(t1,t2)
    << ",\"document_height\":" << height
    << ",\"mid_y\":" << static_cast<double>(mid_pos.y)
    << ",\"end_y\":" << static_cast<double>(end_pos.y)
    << ",\"paint_top_ms\":" << draws[0] << ",\"paint_mid_ms\":" << draws[1]
    << ",\"paint_end_ms\":" << draws[2] << ",\"paint_ops_top\":" << ops[0]
    << ",\"paint_ops_mid\":" << ops[1] << ",\"paint_ops_end\":" << ops[2]
    << ",\"max_rss_bytes\":" << (usage.ru_maxrss) << ",\"incremental_text_edit\":false}\n";
}
