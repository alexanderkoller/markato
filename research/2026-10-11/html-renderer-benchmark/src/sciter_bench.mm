#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/resource.h>

#include "sciter-x.h"
#include "sciter-x-dom.hpp"

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::milli>(b - a).count();
}

static void pump(HWINDOW view) {
  SciterExec(SCITER_APP_LOOP_HEARTBIT, 0, 0);
  SciterUpdateWindow(view);
  [CATransaction flush];
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  std::ifstream in(argv[1], std::ios::binary);
  std::ostringstream buffer;
  buffer << in.rdbuf();
  std::string html = buffer.str();

  @autoreleasepool {
    auto t0 = Clock::now();
    [NSApplication sharedApplication];
    SciterExec(SCITER_APP_INIT, 0, 0);
    RECT frame = {0, 0, 560, 760};
    HWINDOW handle = SciterCreateWindow(0, &frame, nullptr, nullptr, nullptr);
    NSWindow *window = (__bridge NSWindow *)handle;
    NSView *view = [window contentView];
    [window setContentSize:NSMakeSize(560, 760)];
    [window orderFront:nil];
    auto t1 = Clock::now();

    if (!SciterLoadHtml(handle, reinterpret_cast<LPCBYTE>(html.data()),
                        static_cast<UINT>(html.size()), u"about:blank")) return 3;
    pump(handle);
    auto t2 = Clock::now();

    sciter::dom::element root(sciter::dom::element::root_element(handle));
    if (!root.is_valid()) return 4;
    sciter::dom::element edit(root.get_element_by_id("edit-target"));
    sciter::dom::element mid(root.get_element_by_id("mid-target"));
    sciter::dom::element end(root.get_element_by_id("end-target"));
    if (!edit.is_valid() || !mid.is_valid() || !end.is_valid()) return 5;
    RECT root_rect = root.get_location(ROOT_RELATIVE | CONTENT_BOX);
    RECT mid_rect = mid.get_location(ROOT_RELATIVE | BORDER_BOX);
    RECT end_rect = end.get_location(ROOT_RELATIVE | BORDER_BOX);
    auto t3 = Clock::now();

    auto scroll_and_paint = [&](sciter::dom::element &el) {
      auto a = Clock::now();
      el.scroll_to_view(true, false);
      pump(handle);
      auto b = Clock::now();
      return ms(a, b);
    };
    double scroll_top = scroll_and_paint(edit);
    double scroll_mid = scroll_and_paint(mid);
    double scroll_end = scroll_and_paint(end);
    scroll_and_paint(edit);

    auto e0 = Clock::now();
    edit.set_text(u"Edited visible paragraph.");
    edit.update(true);
    pump(handle);
    auto e1 = Clock::now();

    struct rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
    std::cout << "{\"engine\":\"sciter\",\"html_bytes\":" << html.size()
              << ",\"construct_ms\":" << ms(t0, t1)
              << ",\"first_view_ms\":" << ms(t1, t2)
              << ",\"geometry_read_ms\":" << ms(t2, t3)
              << ",\"document_height\":" << std::max(root_rect.bottom - root_rect.top, end_rect.bottom)
              << ",\"mid_y\":" << mid_rect.top
              << ",\"end_y\":" << end_rect.top
              << ",\"scroll_top_ms\":" << scroll_top
              << ",\"scroll_mid_ms\":" << scroll_mid
              << ",\"scroll_end_ms\":" << scroll_end
              << ",\"visible_edit_ms\":" << ms(e0, e1)
              << ",\"max_rss_bytes\":" << usage.ru_maxrss
              << ",\"incremental_text_edit\":true}\n";
    [window orderOut:nil];
    SciterExec(SCITER_APP_SHUTDOWN, 0, 0);
  }
}
