#include <affineui/document.h>
#include <affineui/painter.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/resource.h>

using Clock=std::chrono::steady_clock;
static double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}

class NullPainter final:public affineui::Painter{
 public:
  std::uint64_t ops=0;
  void begin_frame(int,int,float)override{} void end_frame()override{}
  void fill_rect(const affineui::Rect&,affineui::Color)override{++ops;}
  void stroke_rect(const affineui::Rect&,affineui::Color,float)override{++ops;}
  void stroke_line(float,float,float,float,affineui::Color,float)override{++ops;}
  void fill_circle(float,float,float,affineui::Color)override{++ops;}
  void stroke_arc(float,float,float,float,float,affineui::Color,float)override{++ops;}
  void fill_rounded_rect(const affineui::Rect&,float,affineui::Color)override{++ops;}
  void stroke_rounded_rect(const affineui::Rect&,float,affineui::Color,float)override{++ops;}
  void fill_rounded_rect_varying(const affineui::Rect&,float,float,float,float,affineui::Color)override{++ops;}
  void stroke_rounded_rect_varying(const affineui::Rect&,float,float,float,float,affineui::Color,float)override{++ops;}
  void fill_linear_gradient_rect(const affineui::Rect&,float,affineui::Color,affineui::Color,float,float,float,float)override{++ops;}
  void fill_radial_gradient_rect(const affineui::Rect&,affineui::Color,affineui::Color,float,float,float,float,float,float,float)override{++ops;}
  void fill_box_shadow(const affineui::Rect&,float,affineui::Color,float,float,float,float,bool)override{++ops;}
  std::uint32_t resolve_font(std::string_view,int size,int,bool)override{return static_cast<std::uint32_t>(std::max(1,size));}
  int measure_text(std::uint32_t font,std::string_view text)override{return static_cast<int>(std::ceil(font*.52*text.size()));}
  TextMetrics text_metrics(std::uint32_t font)override{return {font*.9f,font*.3f,font*1.2f};}
  void draw_text(std::uint32_t,const affineui::Point&,std::string_view,affineui::Color)override{++ops;}
  affineui::Size measure_text_box(std::uint32_t font,std::string_view text,float max_width,float line_height_mult,float letter_spacing)override{
    float charw=font*.52f+letter_spacing; int per=std::max(1,static_cast<int>(max_width/std::max(1.0f,charw)));
    int lines=std::max(1,static_cast<int>((text.size()+per-1)/per));
    return {static_cast<int>(std::ceil(std::min(max_width,static_cast<float>(text.size())*charw))),
            static_cast<int>(std::ceil(lines*font*1.2f*line_height_mult))};
  }
  void draw_text_box(std::uint32_t,float,float,std::string_view,affineui::Color,float,float,float,TextAlign)override{++ops;}
  std::uint32_t load_image(std::string_view)override{return 0;} affineui::Size image_size(std::uint32_t)override{return {};}
  void draw_image(std::uint32_t,const affineui::Rect&,const affineui::Rect&)override{++ops;}
  void push_clip(const affineui::Rect&)override{} void pop_clip()override{}
  void push_alpha(float)override{} void pop_alpha()override{}
};

int main(int argc,char**argv){
  if(argc!=2)return 2; std::ifstream in(argv[1],std::ios::binary);std::ostringstream ss;ss<<in.rdbuf();std::string html=ss.str();
  affineui::Document doc; NullPainter p;
  auto a=Clock::now();doc.set_html(html);auto b=Clock::now();doc.layout(560,760,&p);auto c=Clock::now();
  auto size=doc.content_size(); auto mid=doc.find_element_rect("#mid-target");auto end=doc.find_element_rect("#end-target");
  p.ops=0;auto d=Clock::now();doc.draw(p);auto e=Clock::now();auto paint_ops=p.ops;
  auto f=Clock::now();bool changed=doc.set_text_by_id("edit-target","BENCH_START_X");auto g=Clock::now();
  bool needs_layout=doc.content_size().width==0;
  if(needs_layout) doc.layout(560,760,&p);auto h=Clock::now();p.ops=0;doc.draw(p);auto i=Clock::now();
  struct rusage usage{};getrusage(RUSAGE_SELF,&usage);
  std::cout<<"{\"engine\":\"affineui\",\"html_bytes\":"<<html.size()
   <<",\"parse_style_ms\":"<<ms(a,b)<<",\"layout_ms\":"<<ms(b,c)<<",\"full_paint_ms\":"<<ms(d,e)
   <<",\"paint_ops\":"<<paint_ops<<",\"document_height\":"<<size.height
   <<",\"mid_y\":"<<mid.y<<",\"end_y\":"<<end.y
   <<",\"edit_mutation_ms\":"<<ms(f,g)<<",\"edit_layout_ms\":"<<ms(g,h)<<",\"edit_paint_ms\":"<<ms(h,i)
   <<",\"edit_changed\":"<<(changed?"true":"false")<<",\"edit_needs_layout\":"<<(needs_layout?"true":"false")<<",\"max_rss_bytes\":"<<usage.ru_maxrss
   <<",\"incremental_text_edit\":true}\n";
}
