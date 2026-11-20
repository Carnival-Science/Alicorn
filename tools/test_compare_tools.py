import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ppm_diff
import theme_contrast


def ppm_bytes(width, height, pixels):
    header = f"P6\n{width} {height}\n255\n".encode("ascii")
    return header + bytes(pixels)


def write(path, data):
    with open(path, "wb") as handle:
        handle.write(data)


STYLE_FIXTURE = """
    result.color_tokens = make([]alicorn.Color, 3, allocator)
    result.color_tokens[0] = alicorn.Color{0.955104589, 0.963987529, 0.990924597, 1}
    result.color_tokens[1] = alicorn.Color{0.00598105974, 0.0100228256, 0.019606648, 1}
    result.color_tokens[2] = alicorn.Color{0.116664723, 0.068384856, 0.245866686, 1}
    result.color_token_provenance = make([]alicorn.Style_Token_Provenance, 3, allocator)
    result.color_token_provenance[0] = alicorn.Style_Token_Provenance{id=1, name="scratchpad.cool.editor_background", alias_target=""}
    result.color_token_provenance[1] = alicorn.Style_Token_Provenance{id=2, name="scratchpad.cool.text", alias_target=""}
    result.color_token_provenance[2] = alicorn.Style_Token_Provenance{id=3, name="scratchpad.cool.syntax.keyword", alias_target=""}
"""


class PpmDiff(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = self.directory.name

    def tearDown(self):
        self.directory.cleanup()

    def test_identical_frames_report_no_difference(self):
        pixels = bytes([10, 20, 30, 40, 50, 60, 70, 80, 90, 1, 2, 3])
        path = os.path.join(self.root, "a.ppm")
        write(path, ppm_bytes(2, 2, pixels))
        width, height, raster = ppm_diff.read_ppm(path)
        self.assertEqual((width, height), (2, 2))
        self.assertEqual(raster, pixels)
        result = ppm_diff.stats(raster, raster, 2, 2)
        self.assertEqual(result["differing_channels"], 0)
        self.assertIsNone(result["bbox"])

    def test_single_pixel_difference_reports_channels_and_bbox(self):
        a = bytes([10, 20, 30, 40, 50, 60, 70, 80, 90, 1, 2, 3])
        b = bytes([10, 20, 30, 40, 50, 60, 70, 80, 90, 6, 2, 3])
        result = ppm_diff.stats(a, b, 2, 2)
        self.assertEqual(result["differing_channels"], 1)
        self.assertEqual(result["differing_pixels"], 1)
        self.assertEqual(result["max_delta"], 5)
        self.assertEqual(result["bbox"], [1, 1, 1, 1])
        self.assertAlmostEqual(result["mean_delta"], 5 / 12)

    def test_region_statistics_only_cover_the_region(self):
        a = bytes(3 * 4 * 3)
        b = bytearray(a)
        b[(2 * 4 + 3) * 3] = 9  # pixel (3,2) only
        result = ppm_diff.stats(a, bytes(b), 4, 3, (0, 0, 2, 2))
        self.assertEqual(result["differing_channels"], 0)
        result = ppm_diff.stats(a, bytes(b), 4, 3, (2, 1, 2, 2))
        self.assertEqual(result["differing_channels"], 1)
        self.assertEqual(result["bbox"], [3, 2, 3, 2])

    def test_regions_clamp_to_the_frame(self):
        self.assertEqual(ppm_diff.clamp_region({"x": -4, "y": 2, "w": 999, "h": 999}, 10, 10), (0, 2, 10, 8))
        self.assertEqual(ppm_diff.clamp_region({"x": 12, "y": 12, "w": 5, "h": 5}, 10, 10), (10, 10, 0, 0))

    def test_comment_lines_are_allowed_in_the_header(self):
        data = b"P6\n# produced by a capture\n3 1\n255\n" + bytes(range(9))
        path = os.path.join(self.root, "commented.ppm")
        write(path, data)
        width, height, raster = ppm_diff.read_ppm(path)
        self.assertEqual((width, height), (3, 1))
        self.assertEqual(len(raster), 9)

    def test_main_writes_json_and_markdown(self):
        pixels = bytes([1, 2, 3, 4, 5, 6])
        a = os.path.join(self.root, "a.ppm")
        b = os.path.join(self.root, "b.ppm")
        write(a, ppm_bytes(2, 1, pixels))
        write(b, ppm_bytes(2, 1, bytes([1, 2, 3, 4, 5, 7])))
        json_out = os.path.join(self.root, "diff.json")
        md_out = os.path.join(self.root, "diff.md")
        with contextlib.redirect_stderr(io.StringIO()):
            code = ppm_diff.main(
                ["--a", a, "--b", b, "--json-out", json_out, "--md-out", md_out, "--quiet",
                 "--label-a", "hosted", "--label-b", "reference"]
            )
            failing = ppm_diff.main(["--a", a, "--b", b, "--quiet", "--fail-on-diff"])
        self.assertEqual(code, 0)
        with open(md_out, "r", encoding="utf-8") as handle:
            markdown = handle.read()
        self.assertIn("full frame", markdown)
        self.assertIn("hosted vs reference", markdown)
        self.assertEqual(failing, 3)


class ThemeContrast(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, "style_test_generated.odin")
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(STYLE_FIXTURE)

    def tearDown(self):
        self.directory.cleanup()

    def test_stored_values_round_trip_to_displayed_and_authored_colors(self):
        self.assertEqual(theme_contrast.stored_to_displayed(0.955104589), 244)
        self.assertEqual(theme_contrast.stored_to_authored(0.955104589), 250)
        self.assertEqual(theme_contrast.stored_to_displayed(0.116664723), 30)
        self.assertEqual(theme_contrast.stored_to_authored(0.116664723), 96)

    def test_contrast_ratio_matches_wcag_reference_values(self):
        self.assertAlmostEqual(theme_contrast.contrast_ratio((0, 0, 0), (255, 255, 255)), 21.0, places=4)
        self.assertAlmostEqual(theme_contrast.contrast_ratio((255, 255, 255), (0, 0, 0)), 21.0, places=4)

    def test_analysis_separates_displayed_from_authored_tokens(self):
        tokens = theme_contrast.parse_style(self.path)
        report = theme_contrast.analyse(tokens, "fixture")
        self.assertEqual(report["displayed"]["background_hex"], "#f4f6fd")
        self.assertEqual(report["authored"]["background_hex"], "#fafbfe")
        self.assertEqual(report["displayed"]["text_hex"], "#020305")
        keyword = report["tokens"][0]
        self.assertEqual(keyword["class"], "keyword")
        self.assertEqual(keyword["displayed_hex"], "#1e113f")
        self.assertEqual(keyword["authored_hex"], "#604a88")
        self.assertGreater(keyword["displayed_vs_background"], 15)
        self.assertLess(keyword["displayed_vs_baseline"], 1.2)

    def test_markdown_reports_both_color_spaces(self):
        report = theme_contrast.analyse(theme_contrast.parse_style(self.path), "fixture")
        document = theme_contrast.markdown([report])
        self.assertIn("displayed", document)
        self.assertIn("Authored intent", document)
        self.assertIn("#1e113f", document)
        self.assertIn("#604a88", document)


if __name__ == "__main__":
    unittest.main()
