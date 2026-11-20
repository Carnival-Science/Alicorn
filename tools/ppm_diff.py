#!/usr/bin/env python3
"""Compare two binary PPM (P6) frames and report channel/region deltas.

This is the diff half of `tools/compare_backends.ps1`, the matched dual-backend
comparison harness. It is deliberately dependency-free so it runs anywhere the
repository's other Python checks run.

Usage:
    python tools/ppm_diff.py --a reference.ppm --b hosted.ppm
    python tools/ppm_diff.py --a reference.ppm --b hosted.ppm \
        --regions tools/compare_regions.json --json-out diff.json --md-out diff.md

Exit status: 0 when the tool ran (match or mismatch), 2 on usage/parse errors,
and 3 when --fail-on-diff is set and the frames differ.
"""

from __future__ import annotations

import argparse
import json
import sys


def read_ppm(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise SystemExit(f"ppm_diff: cannot read {path}: {error}")

    tokens = []
    index = 0
    length = len(data)
    if not data.startswith(b"P6"):
        raise SystemExit(f"ppm_diff: {path} is not a binary PPM (P6)")
    while len(tokens) < 4:
        while index < length and data[index] in b" \t\r\n":
            index += 1
        if index < length and data[index] == ord("#"):
            while index < length and data[index] not in b"\r\n":
                index += 1
            continue
        start = index
        while index < length and data[index] not in b" \t\r\n":
            index += 1
        if start == index:
            raise SystemExit(f"ppm_diff: truncated PPM header in {path}")
        tokens.append(data[start:index])
    index += 1  # single whitespace byte before the raster
    if tokens[0] != b"P6":
        raise SystemExit(f"ppm_diff: {path} is not a binary PPM (P6)")
    width, height, maxval = int(tokens[1]), int(tokens[2]), int(tokens[3])
    if maxval != 255:
        raise SystemExit(f"ppm_diff: {path} has maxval {maxval}, expected 255")
    raster = data[index:]
    if len(raster) != width * height * 3:
        raise SystemExit(
            f"ppm_diff: {path} raster is {len(raster)} bytes, expected "
            f"{width * height * 3} for {width}x{height}"
        )
    return width, height, raster


def clamp_region(region, width, height):
    x = max(0, min(int(region.get("x", 0)), width))
    y = max(0, min(int(region.get("y", 0)), height))
    w = max(0, min(int(region.get("w", width - x)), width - x))
    h = max(0, min(int(region.get("h", height - y)), height - y))
    return x, y, w, h


def stats(a, b, width, height, region=None):
    if region is None:
        x, y, w, h = 0, 0, width, height
        pixels = width * height
    else:
        x, y, w, h = region
        pixels = w * h
    channels = pixels * 3
    differing_channels = 0
    differing_pixels = 0
    max_delta = 0
    total_delta = 0
    min_x = width
    min_y = height
    max_x = -1
    max_y = -1
    for row in range(y, y + h):
        row_start = (row * width + x) * 3
        row_end = row_start + w * 3
        a_row = a[row_start:row_end]
        b_row = b[row_start:row_end]
        if a_row == b_row:
            continue
        for column in range(w):
            offset = column * 3
            delta = 0
            for channel in range(3):
                difference = a_row[offset + channel] - b_row[offset + channel]
                if difference:
                    delta += abs(difference)
                    differing_channels += 1
            if delta:
                differing_pixels += 1
                total_delta += delta
                if delta > max_delta:
                    max_delta = delta
                pixel_x = x + column
                if pixel_x < min_x:
                    min_x = pixel_x
                if pixel_x > max_x:
                    max_x = pixel_x
                if row < min_y:
                    min_y = row
                if row > max_y:
                    max_y = row
    bbox = None
    if differing_pixels:
        bbox = [min_x, min_y, max_x, max_y]
    return {
        "rect": [x, y, w, h],
        "pixels": pixels,
        "channels": channels,
        "differing_channels": differing_channels,
        "differing_channels_percent": (
            100.0 * differing_channels / channels if channels else 0.0
        ),
        "differing_pixels": differing_pixels,
        "differing_pixels_percent": (
            100.0 * differing_pixels / pixels if pixels else 0.0
        ),
        "max_delta": max_delta,
        "mean_delta": (total_delta / channels) if channels else 0.0,
        "mean_differing_channel_delta": (
            total_delta / differing_channels if differing_channels else 0.0
        ),
        "bbox": bbox,
    }


def load_regions(path, width, height):
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    entries = document.get("regions", document) if isinstance(document, dict) else document
    regions = []
    for entry in entries:
        name = entry.get("name", "region")
        regions.append({"name": name, "rect": clamp_region(entry, width, height)})
    return regions


def format_bbox(bbox):
    if not bbox:
        return "-"
    return f"({bbox[0]},{bbox[1]})-({bbox[2]},{bbox[3]})"


def markdown(result, label_a, label_b):
    lines = []
    lines.append(f"### {label_a} vs {label_b}")
    lines.append("")
    lines.append("| Frame | Differing channels | Max | Mean | Differing pixels | Bounding box |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    full = result["full"]
    lines.append(
        "| full frame | {dc} / {ch} ({pct:.2f}%) | {mx} | {mean:.4f} | {dp} / {px} | {bbox} |".format(
            dc=full["differing_channels"],
            ch=full["channels"],
            pct=full["differing_channels_percent"],
            mx=full["max_delta"],
            mean=full["mean_delta"],
            dp=full["differing_pixels"],
            px=full["pixels"],
            bbox=format_bbox(full["bbox"]),
        )
    )
    for region in result["regions"]:
        lines.append(
            "| {name} | {dc} / {ch} ({pct:.2f}%) | {mx} | {mean:.4f} | {dp} / {px} | {bbox} |".format(
                name=region["name"],
                dc=region["differing_channels"],
                ch=region["channels"],
                pct=region["differing_channels_percent"],
                mx=region["max_delta"],
                mean=region["mean_delta"],
                dp=region["differing_pixels"],
                px=region["pixels"],
                bbox=format_bbox(region["bbox"]),
            )
        )
    lines.append("")
    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--a", required=True, help="reference PPM")
    parser.add_argument("--b", required=True, help="candidate PPM")
    parser.add_argument("--label-a", default="reference")
    parser.add_argument("--label-b", default="candidate")
    parser.add_argument("--regions", help="JSON region list")
    parser.add_argument("--json-out", help="write the JSON result here")
    parser.add_argument("--md-out", help="write the markdown fragment here")
    parser.add_argument("--quiet", action="store_true", help="print only the summary line")
    parser.add_argument(
        "--fail-on-diff", action="store_true", help="exit 3 when any channel differs"
    )
    options = parser.parse_args(argv)

    width_a, height_a, raster_a = read_ppm(options.a)
    width_b, height_b, raster_b = read_ppm(options.b)
    if (width_a, height_a) != (width_b, height_b):
        raise SystemExit(
            f"ppm_diff: size mismatch: {options.a} is {width_a}x{height_a}, "
            f"{options.b} is {width_b}x{height_b}"
        )

    result = {
        "a": {"path": options.a, "label": options.label_a},
        "b": {"path": options.b, "label": options.label_b},
        "size": [width_a, height_a],
        "full": stats(raster_a, raster_b, width_a, height_a),
        "regions": [],
    }
    if options.regions:
        for region in load_regions(options.regions, width_a, height_a):
            entry = stats(raster_a, raster_b, width_a, height_a, region["rect"])
            entry["name"] = region["name"]
            result["regions"].append(entry)

    if options.json_out:
        with open(options.json_out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
            handle.write("\n")
    if options.md_out:
        with open(options.md_out, "w", encoding="utf-8") as handle:
            fragment = markdown(result, options.label_a, options.label_b)
            handle.write(fragment if fragment.endswith("\n") else fragment + "\n")
    if not options.quiet:
        print(json.dumps(result, indent=2))

    full = result["full"]
    print(
        "ppm_diff: {w}x{h} channels={ch} differing={dc} ({pct:.2f}%) max={mx} "
        "mean={mean:.4f} pixels={dp} bbox={bbox}".format(
            w=width_a,
            h=height_a,
            ch=full["channels"],
            dc=full["differing_channels"],
            pct=full["differing_channels_percent"],
            mx=full["max_delta"],
            mean=full["mean_delta"],
            dp=full["differing_pixels"],
            bbox=format_bbox(full["bbox"]),
        ),
        file=sys.stderr,
    )
    if options.fail_on_diff and full["differing_channels"]:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
