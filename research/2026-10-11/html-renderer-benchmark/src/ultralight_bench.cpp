#include <Ultralight/Ultralight.h>
#include <Ultralight/DOM.h>
#include <AppCore/AppCore.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/resource.h>
#include <thread>

using namespace ultralight;
using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::milli>(b-a).count();
}

class Bench final : public LoadListener, public Logger {
 public:
  RefPtr<Renderer> renderer;
  RefPtr<View> view;
  dom::Triggers triggers;
  dom::Document doc;
  dom::Element root, edit;
  bool dom_ready=false, loaded=false;
  Clock::time_point start, dom_at, load_at;

  Bench() {
    Config config;
    config.resource_path_prefix = "resources/";
    Platform::instance().set_config(config);
    Platform::instance().set_font_loader(GetPlatformFontLoader());
    Platform::instance().set_file_system(GetPlatformFileSystem("."));
    Platform::instance().set_logger(this);
    renderer=Renderer::Create();
    ViewConfig vc; vc.initial_device_scale=1.0; vc.is_accelerated=false; vc.enable_javascript=false;
    view=renderer->CreateView(560,760,vc,nullptr);
    view->set_load_listener(this);
    triggers.OnDOMReady([this](dom::Document d) {
      doc=d; root=doc.documentElement(); edit=doc.getElementById("edit-target");
      dom_at=Clock::now(); dom_ready=true;
    });
    if (!triggers.AttachTo(view.get())) throw std::runtime_error("DOM API attach failed");
  }
  ~Bench() { view=nullptr; renderer=nullptr; }
  void OnDOMReady(View*, uint64_t, bool, const String&) override {}
  void OnFinishLoading(View*, uint64_t, bool, const String&) override { loaded=true; load_at=Clock::now(); }
  void LogMessage(LogLevel level, const String& message) override {
    if (level >= LogLevel::Error) std::cerr << message.utf8().data() << "\n";
  }
  double paint_once() {
    auto a=Clock::now(); renderer->RefreshDisplay(0); renderer->Render(); auto b=Clock::now(); return ms(a,b);
  }
  bool pump_until_ready(double& first_paint_ms) {
    auto deadline=Clock::now()+std::chrono::seconds(120);
    while (Clock::now()<deadline) {
      renderer->Update();
      if (dom_ready) { first_paint_ms=paint_once(); return true; }
      renderer->RefreshDisplay(0); renderer->Render();
    }
    return false;
  }
};

int main(int argc,char** argv) {
  if(argc!=2) return 2;
  std::ifstream in(argv[1],std::ios::binary); std::ostringstream ss; ss<<in.rdbuf();
  std::string html=ss.str();
  auto construct_a=Clock::now(); Bench b; auto construct_b=Clock::now();
  b.start=Clock::now(); b.view->LoadHTML(html.c_str()); auto load_return=Clock::now();
  double first_render=0;
  if(!b.pump_until_ready(first_render)) { std::cerr<<"timeout\n"; return 3; }
  auto first_ready=Clock::now();
  int height=b.root.scrollHeight();
  auto geometry_ready=Clock::now();
  double scroll_times[3]{};
  const double ys[3]={0.0,std::max(0.0,(height-760)/2.0),std::max(0.0,height-760.0)};
  auto win=b.doc.defaultView();
  for(int i=0;i<3;i++) { auto a=Clock::now(); win.scrollTo(0,ys[i]); b.renderer->Update(); b.paint_once(); auto c=Clock::now(); scroll_times[i]=ms(a,c); }
  win.scrollTo(0,0); b.renderer->Update(); b.paint_once();
  auto edit_a=Clock::now(); b.edit.textContent="BENCH_START_X"; b.renderer->Update(); b.paint_once(); auto edit_b=Clock::now();
  struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
  std::cout<<"{\"engine\":\"ultralight\",\"html_bytes\":"<<html.size()
    <<",\"construct_ms\":"<<ms(construct_a,construct_b)
    <<",\"load_call_ms\":"<<ms(b.start,load_return)
    <<",\"dom_ready_ms\":"<<ms(b.start,b.dom_at)
    <<",\"first_view_ms\":"<<ms(b.start,first_ready)
    <<",\"first_render_call_ms\":"<<first_render
    <<",\"geometry_read_ms\":"<<ms(first_ready,geometry_ready)
    <<",\"document_height\":"<<height
    <<",\"scroll_top_ms\":"<<scroll_times[0]<<",\"scroll_mid_ms\":"<<scroll_times[1]
    <<",\"scroll_end_ms\":"<<scroll_times[2]<<",\"visible_edit_ms\":"<<ms(edit_a,edit_b)
    <<",\"max_rss_bytes\":"<<usage.ru_maxrss<<",\"incremental_text_edit\":true}\n";
}
