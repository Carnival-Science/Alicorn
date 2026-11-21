// wxWidgets reference capture for Alicorn issues #200 and #201.
//
// Alicorn's GPU readback is compared against the rasterization wxWidgets
// produces for the same logical scene. The scene is a plain text file written
// by the Alicorn validation executables, so both sides consume one definition:
//
//   scene 1
//   size <logical_width> <logical_height>
//   scale <dpi_scale>
//   bg <r> <g> <b>
//   ellipse <x> <y> <w> <h> <r> <g> <b>      // wxDC::DrawEllipse(wxRect)
//   rect <x> <y> <w> <h> <r> <g> <b> <a>     // wxDC::DrawRectangle(wxRect)
//
// Audacity's WaveformView draws its sample markers with
// `dc.DrawEllipse(wxRect)` and its waveform background fills with
// `dc.DrawRectangle(...)`, so this exercises the same wxDC entry points. A
// wxDC is always in device pixels, so each shape's logical rect is scaled by
// the DPI factor and rounded before it reaches wx: the same integer rect an
// Audacity-side host would pass.
//
// Output: <prefix>.rgb (tightly packed RGB24, top-down) and <prefix>.meta:
//   wx_reference 1 <wx version> <logical_w> <logical_h> <scale> <px_w> <px_h>
//   <bg r> <bg g> <bg b> <file>
//
// The tool also times the draw loop and prints p50/p95 per-frame costs so the
// "wx path" half of the repaint-cost comparison is measured on the same
// machine.

#include <wx/wx.h>
#include <wx/dcmemory.h>
#include <wx/image.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct Shape {
    enum Kind { Ellipse, Rect } kind;
    double x, y, w, h;
    unsigned char r, g, b, a;
};

struct Scene {
    int logical_width = 0;
    int logical_height = 0;
    double scale = 1.0;
    unsigned char bg_r = 0, bg_g = 0, bg_b = 0;
    std::vector<Shape> shapes;
};

static bool load_scene(const char* path, Scene& scene) {
    FILE* file = std::fopen(path, "rb");
    if (!file) { std::fprintf(stderr, "wx_reference: cannot open scene '%s'\n", path); return false; }
    char line[512];
    bool saw_header = false;
    while (std::fgets(line, sizeof line, file)) {
        char* cursor = line;
        while (*cursor == ' ' || *cursor == '\t') ++cursor;
        if (*cursor == '#' || *cursor == '\n' || *cursor == '\r' || *cursor == 0) continue;
        if (std::strncmp(cursor, "scene ", 6) == 0) {
            int version = 0;
            if (std::sscanf(cursor, "scene %d", &version) != 1 || version != 1) {
                std::fprintf(stderr, "wx_reference: unsupported scene version\n");
                std::fclose(file);
                return false;
            }
            saw_header = true;
        } else if (std::strncmp(cursor, "size ", 5) == 0) {
            if (std::sscanf(cursor, "size %d %d", &scene.logical_width, &scene.logical_height) != 2) {
                std::fprintf(stderr, "wx_reference: bad size line\n"); std::fclose(file); return false;
            }
        } else if (std::strncmp(cursor, "scale ", 6) == 0) {
            if (std::sscanf(cursor, "scale %lf", &scene.scale) != 1) {
                std::fprintf(stderr, "wx_reference: bad scale line\n"); std::fclose(file); return false;
            }
        } else if (std::strncmp(cursor, "bg ", 3) == 0) {
            int r = 0, g = 0, b = 0;
            if (std::sscanf(cursor, "bg %d %d %d", &r, &g, &b) != 3) {
                std::fprintf(stderr, "wx_reference: bad bg line\n"); std::fclose(file); return false;
            }
            scene.bg_r = (unsigned char)r; scene.bg_g = (unsigned char)g; scene.bg_b = (unsigned char)b;
        } else if (std::strncmp(cursor, "ellipse ", 8) == 0) {
            Shape shape{};
            shape.kind = Shape::Ellipse;
            int r = 0, g = 0, b = 0;
            if (std::sscanf(cursor, "ellipse %lf %lf %lf %lf %d %d %d",
                    &shape.x, &shape.y, &shape.w, &shape.h, &r, &g, &b) != 7) {
                std::fprintf(stderr, "wx_reference: bad ellipse line\n"); std::fclose(file); return false;
            }
            shape.r = (unsigned char)r; shape.g = (unsigned char)g; shape.b = (unsigned char)b; shape.a = 255;
            scene.shapes.push_back(shape);
        } else if (std::strncmp(cursor, "rect ", 5) == 0) {
            Shape shape{};
            shape.kind = Shape::Rect;
            int r = 0, g = 0, b = 0, a = 255;
            if (std::sscanf(cursor, "rect %lf %lf %lf %lf %d %d %d %d",
                    &shape.x, &shape.y, &shape.w, &shape.h, &r, &g, &b, &a) != 8) {
                std::fprintf(stderr, "wx_reference: bad rect line\n"); std::fclose(file); return false;
            }
            shape.r = (unsigned char)r; shape.g = (unsigned char)g; shape.b = (unsigned char)b;
            shape.a = (unsigned char)a;
            if (shape.a != 255) {
                std::fprintf(stderr, "wx_reference: wxDC has no alpha blending; only opaque rects are supported\n");
                std::fclose(file);
                return false;
            }
            scene.shapes.push_back(shape);
        } else {
            std::fprintf(stderr, "wx_reference: unknown scene line '%.32s'\n", cursor);
            std::fclose(file);
            return false;
        }
    }
    std::fclose(file);
    if (!saw_header || scene.logical_width <= 0 || scene.logical_height <= 0 || scene.scale <= 0) {
        std::fprintf(stderr, "wx_reference: incomplete scene\n");
        return false;
    }
    return true;
}

static long long now_ns() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

static long long percentile(std::vector<long long> values, double p) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    size_t index = (size_t)std::ceil(values.size() * p);
    if (index == 0) index = 1;
    if (index > values.size()) index = values.size();
    return values[index - 1];
}

static void draw_scene(wxDC& dc, const Scene& scene) {
    dc.SetBackground(wxBrush(wxColour(scene.bg_r, scene.bg_g, scene.bg_b)));
    dc.Clear();
    dc.SetPen(*wxTRANSPARENT_PEN);
    // A wxDC always draws in device pixels. A DPI-aware host scales its
    // logical rect into the device rect and passes integers to wx, which is
    // exactly how Audacity's WaveformView reaches DrawEllipse/DrawRectangle.
    // Scaling the DC instead would also scale wxMSW's internal `+1` ellipse
    // box padding, which is not a property any host can observe.
    for (const Shape& shape : scene.shapes) {
        double x = std::floor(shape.x * scene.scale + 0.5);
        double y = std::floor(shape.y * scene.scale + 0.5);
        double w = std::floor(shape.w * scene.scale + 0.5);
        double h = std::floor(shape.h * scene.scale + 0.5);
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        dc.SetBrush(wxBrush(wxColour(shape.r, shape.g, shape.b)));
        wxRect rect((int)x, (int)y, (int)w, (int)h);
        if (shape.kind == Shape::Ellipse) dc.DrawEllipse(rect);
        else dc.DrawRectangle(rect);
    }
}

class App : public wxApp {
public:
    bool OnInit() override {
        std::exit(run());
    }

    int run() {
        int status = 0;
        for (int index = 1; index < argc; ++index) {
            std::string argument = argv[index];
            if (argument.rfind("--scene=", 0) == 0) scene_path = argument.substr(8);
            else if (argument.rfind("--out=", 0) == 0) output_prefix = argument.substr(6);
            else if (argument.rfind("--repeat=", 0) == 0) repeat = std::atoi(argument.c_str() + 9);
            else if (argument == "--help") {
                std::printf("usage: wx_reference --scene=<file> --out=<prefix> [--repeat=N]\n");
                return 0;
            } else {
                std::fprintf(stderr, "wx_reference: unknown argument '%s'\n", argument.c_str());
                return 2;
            }
        }
        if (scene_path.empty() || output_prefix.empty()) {
            std::fprintf(stderr, "wx_reference: --scene and --out are required\n");
            return 2;
        }
        Scene scene;
        if (!load_scene(scene_path.c_str(), scene)) return 2;

        const int px_w = std::max(1, (int)std::floor(scene.logical_width * scene.scale + 0.5));
        const int px_h = std::max(1, (int)std::floor(scene.logical_height * scene.scale + 0.5));
        wxBitmap bitmap(px_w, px_h, 24);
        if (!bitmap.IsOk()) {
            std::fprintf(stderr, "wx_reference: bitmap allocation failed\n");
            return 3;
        }

        std::vector<long long> frame_ns;
        wxMemoryDC dc;
        dc.SelectObject(bitmap);
        if (!dc.IsOk()) {
            std::fprintf(stderr, "wx_reference: memory DC selection failed\n");
            return 3;
        }
        if (repeat < 1) repeat = 1;
        // Warm up GDI/bitmap state so the first iteration is not mistaken for
        // steady-state wx drawing cost.
        draw_scene(dc, scene);
        for (int iteration = 0; iteration < repeat; ++iteration) {
            const long long started = now_ns();
            draw_scene(dc, scene);
            frame_ns.push_back(now_ns() - started);
        }
        dc.SelectObject(wxNullBitmap);

        wxImage image = bitmap.ConvertToImage();
        if (!image.IsOk() || image.HasAlpha()) {
            std::fprintf(stderr, "wx_reference: unexpected converted image\n");
            return 3;
        }
        const std::string rgb_path = output_prefix + ".rgb";
        FILE* out = std::fopen(rgb_path.c_str(), "wb");
        if (!out) {
            std::fprintf(stderr, "wx_reference: cannot write '%s'\n", rgb_path.c_str());
            return 3;
        }
        const size_t bytes = (size_t)px_w * (size_t)px_h * 3;
        if (std::fwrite(image.GetData(), 1, bytes, out) != bytes) {
            std::fprintf(stderr, "wx_reference: short write to '%s'\n", rgb_path.c_str());
            std::fclose(out);
            return 3;
        }
        std::fclose(out);

        const std::string meta_path = output_prefix + ".meta";
        FILE* meta = std::fopen(meta_path.c_str(), "wb");
        if (!meta) {
            std::fprintf(stderr, "wx_reference: cannot write '%s'\n", meta_path.c_str());
            return 3;
        }
        std::fprintf(meta, "wx_reference 1 %d.%d.%d %d %d %.6f %d %d\n",
                     wxMAJOR_VERSION, wxMINOR_VERSION, wxRELEASE_NUMBER,
                     scene.logical_width, scene.logical_height, scene.scale, px_w, px_h);
        std::fprintf(meta, "%d %d %d %s %zu\n", (int)scene.bg_r, (int)scene.bg_g, (int)scene.bg_b,
                     rgb_path.c_str(), scene.shapes.size());
        std::fclose(meta);

        const long long p50 = percentile(frame_ns, 0.50);
        const long long p95 = percentile(frame_ns, 0.95);
        std::printf("wx_reference_cost shapes=%zu kind=%s scale=%.2f pixels=%dx%d frames=%d "
                    "draw_p50_ns=%lld draw_p95_ns=%lld\n",
                    scene.shapes.size(),
                    (!scene.shapes.empty() && scene.shapes[0].kind == Shape::Rect) ? "rect" : "ellipse",
                    scene.scale, px_w, px_h, repeat, p50, p95);
        return status;
    }

private:
    std::string scene_path;
    std::string output_prefix;
    int repeat = 64;
};

wxIMPLEMENT_APP_NO_MAIN(App);
int main(int argc, char** argv) { return wxEntry(argc, argv); }
