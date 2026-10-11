#include <Ultralight/DOM.h>
#include <Ultralight/Ultralight.h>
#include <AppCore/AppCore.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <vector>

using namespace ultralight;
using Clock = std::chrono::steady_clock;

static double ms(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::milli>(b - a).count();
}

static std::string read_file(const char* path) {
  std::ifstream in(path, std::ios::binary);
  if (!in)
    throw std::runtime_error("unable to read fixture");
  std::ostringstream stream;
  stream << in.rdbuf();
  return stream.str();
}

struct Fixture {
  std::string prefix;
  std::vector<std::string> blocks;
};

static Fixture split_fixture(const std::string& html) {
  const std::string marker = "<main id=preview>";
  size_t main = html.find(marker);
  if (main == std::string::npos)
    throw std::runtime_error("fixture main element missing");
  Fixture result;
  result.prefix = html.substr(0, main + marker.size());
  size_t cursor = main + marker.size();
  while (true) {
    size_t begin = html.find("<section", cursor);
    if (begin == std::string::npos)
      break;
    size_t end = html.find("</section>", begin);
    if (end == std::string::npos)
      throw std::runtime_error("unterminated section");
    end += std::string("</section>").size();
    result.blocks.push_back(html.substr(begin, end - begin));
    cursor = end;
  }
  if (result.blocks.empty())
    throw std::runtime_error("fixture blocks missing");
  return result;
}

static std::string block_range(const Fixture& fixture, size_t begin, size_t count) {
  const size_t end = std::min(fixture.blocks.size(), begin + count);
  std::string result;
  for (size_t index = begin; index < end; ++index)
    result += fixture.blocks[index];
  return result;
}

static std::string document_for(const Fixture& fixture, size_t begin, size_t count) {
  return fixture.prefix + block_range(fixture, begin, count) + "</main></body></html>";
}

class Bench final : public Logger {
 public:
  RefPtr<Renderer> renderer;
  RefPtr<View> view;
  dom::Triggers triggers;
  dom::Document document;
  dom::Element root;
  bool dom_ready = false;

  Bench() {
    Config config;
    config.resource_path_prefix = "resources/";
    Platform::instance().set_config(config);
    Platform::instance().set_font_loader(GetPlatformFontLoader());
    Platform::instance().set_file_system(GetPlatformFileSystem("."));
    Platform::instance().set_logger(this);
    renderer = Renderer::Create();
    ViewConfig view_config;
    view_config.initial_device_scale = 1.0;
    view_config.is_accelerated = false;
    view_config.enable_javascript = false;
    view = renderer->CreateView(560, 760, view_config, nullptr);
    triggers.OnDOMReady([this](dom::Document ready_document) {
      document = ready_document;
      root = document.getElementById("preview");
      dom_ready = true;
    });
    if (!triggers.AttachTo(view.get()))
      throw std::runtime_error("DOM API attach failed");
  }

  ~Bench() {
    view = nullptr;
    renderer = nullptr;
  }

  void LogMessage(LogLevel level, const String& message) override {
    if (level >= LogLevel::Error)
      std::cerr << message.utf8().data() << "\n";
  }

  void update_and_render() {
    renderer->Update();
    renderer->RefreshDisplay(0);
    renderer->Render();
  }

  bool load(const std::string& html) {
    view->LoadHTML(html.c_str());
    const auto deadline = Clock::now() + std::chrono::seconds(30);
    while (!dom_ready && Clock::now() < deadline)
      update_and_render();
    if (!dom_ready || !root)
      return false;
    update_and_render();
    return true;
  }

  double timed_commit() {
    auto begin = Clock::now();
    update_and_render();
    auto end = Clock::now();
    return ms(begin, end);
  }
};

int main(int argc, char** argv) {
  if (argc < 2 || argc > 5)
    return 2;
  try {
    const std::string source = read_file(argv[1]);
    const Fixture fixture = split_fixture(source);
    const size_t requested_window = argc >= 3 ? std::stoul(argv[2]) : 256;
    const size_t window_blocks = std::min(requested_window, fixture.blocks.size());
    const size_t requested_shift = argc >= 4 ? std::stoul(argv[3]) : window_blocks / 8;
    const size_t shift_blocks = std::min(requested_shift, window_blocks / 2);
    const bool prewarm_shell = argc == 5 && std::string(argv[4]) == "prewarm";

    Bench bench;
    const std::string initial = document_for(fixture, 0, window_blocks);
    auto load_begin = Clock::now();
    const std::string shell = fixture.prefix + "</main></body></html>";
    if (!bench.load(prewarm_shell ? shell : initial)) {
      std::cerr << "timeout\n";
      return 3;
    }
    auto shell_ready = Clock::now();
    double first_content_ms = -1;
    if (prewarm_shell) {
      auto content_begin = Clock::now();
      bench.root.innerHTML = block_range(fixture, 0, window_blocks);
      bench.update_and_render();
      first_content_ms = ms(content_begin, Clock::now());
    }
    auto load_end = Clock::now();
    const int initial_height = bench.root.scrollHeight();

    auto window = bench.document.defaultView();
    const double local_middle = std::max(0.0, (initial_height - 760) / 2.0);
    const double local_end = std::max(0.0, initial_height - 760.0);
    auto scroll_middle_begin = Clock::now();
    window.scrollTo(0, local_middle);
    bench.update_and_render();
    auto scroll_middle_end = Clock::now();
    auto scroll_end_begin = Clock::now();
    window.scrollTo(0, local_end);
    bench.update_and_render();
    auto scroll_end_end = Clock::now();
    window.scrollTo(0, 0);
    bench.update_and_render();

    auto measure_begin = Clock::now();
    size_t measured = 0;
    int height_checksum = 0;
    for (auto element = bench.root.firstElementChild(); element;
         element = element.nextElementSibling()) {
      height_checksum += element.offsetHeight();
      ++measured;
    }
    auto measure_end = Clock::now();

    auto retained_before = bench.document.querySelector("[data-block='64']");
    auto patch_begin = Clock::now();
    for (size_t index = 0; index < shift_blocks; ++index)
      bench.root.firstElementChild().remove();
    bench.root.insertAdjacentHTML(
        "beforeend", block_range(fixture, window_blocks, shift_blocks));
    const double patch_commit = bench.timed_commit();
    auto patch_end = Clock::now();
    auto retained_after = bench.document.querySelector("[data-block='64']");
    const bool overlap_retained = retained_before && retained_after &&
                                  retained_before.IsSame(retained_after);

    auto reverse_begin = Clock::now();
    for (size_t index = 0; index < shift_blocks; ++index)
      bench.root.lastElementChild().remove();
    bench.root.insertAdjacentHTML("afterbegin", block_range(fixture, 0, shift_blocks));
    const double reverse_commit = bench.timed_commit();
    auto reverse_end = Clock::now();

    const std::string adjacent = block_range(fixture, shift_blocks, window_blocks);
    auto replace_begin = Clock::now();
    bench.root.innerHTML = adjacent;
    const double replace_commit = bench.timed_commit();
    auto replace_end = Clock::now();

    const size_t middle_begin = fixture.blocks.size() > window_blocks
        ? (fixture.blocks.size() - window_blocks) / 2
        : 0;
    const std::string middle = block_range(fixture, middle_begin, window_blocks);
    auto jump_begin = Clock::now();
    bench.root.innerHTML = middle;
    const double jump_commit = bench.timed_commit();
    auto jump_end = Clock::now();

    auto edit_target = bench.root.firstElementChild();
    auto edit_begin = Clock::now();
    edit_target.textContent = "Visible semantic block changed in place.";
    const double edit_commit = bench.timed_commit();
    auto edit_end = Clock::now();

    const int final_height = bench.root.scrollHeight();
    struct rusage usage {};
    getrusage(RUSAGE_SELF, &usage);

    std::cout << "{\"engine\":\"ultralight-window\""
              << ",\"fixture_html_bytes\":" << source.size()
              << ",\"fixture_blocks\":" << fixture.blocks.size()
              << ",\"window_blocks\":" << window_blocks
              << ",\"window_html_bytes\":" << block_range(fixture, 0, window_blocks).size()
              << ",\"shift_blocks\":" << shift_blocks
              << ",\"initial_view_ms\":" << ms(load_begin, load_end)
              << ",\"shell_ready_ms\":" << ms(load_begin, shell_ready)
              << ",\"prewarmed_first_content_ms\":" << first_content_ms
              << ",\"initial_height\":" << initial_height
              << ",\"local_scroll_middle_ms\":" << ms(scroll_middle_begin, scroll_middle_end)
              << ",\"local_scroll_end_ms\":" << ms(scroll_end_begin, scroll_end_end)
              << ",\"measure_all_ms\":" << ms(measure_begin, measure_end)
              << ",\"measured_blocks\":" << measured
              << ",\"height_checksum\":" << height_checksum
              << ",\"adjacent_patch_ms\":" << ms(patch_begin, patch_end)
              << ",\"adjacent_commit_ms\":" << patch_commit
              << ",\"overlap_retained\":" << (overlap_retained ? "true" : "false")
              << ",\"reverse_patch_ms\":" << ms(reverse_begin, reverse_end)
              << ",\"reverse_commit_ms\":" << reverse_commit
              << ",\"adjacent_replace_ms\":" << ms(replace_begin, replace_end)
              << ",\"adjacent_replace_commit_ms\":" << replace_commit
              << ",\"deep_jump_ms\":" << ms(jump_begin, jump_end)
              << ",\"deep_jump_commit_ms\":" << jump_commit
              << ",\"visible_edit_ms\":" << ms(edit_begin, edit_end)
              << ",\"visible_edit_commit_ms\":" << edit_commit
              << ",\"final_height\":" << final_height
              << ",\"max_rss_bytes\":" << usage.ru_maxrss << "}\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 4;
  }
}
