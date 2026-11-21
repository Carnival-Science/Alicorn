#!/usr/bin/env python3
"""Measure syntax-token contrast in Alicorn generated style themes.

The theme compiler stores Theme_Color/Color channels as linear-sRGB and both
SDL_GPU and hosted WebGPU write those channels unchanged into a non-sRGB
swapchain (`docs/themes.md`). A generated `style_*_generated.odin` therefore
contains two different colors for every authored token:

  * authored / design intent: sRGB, recovered by sRGB-encoding the stored value
  * displayed / rendered: the stored linear value interpreted as sRGB

This tool reports WCAG 2.1 contrast ratios and CIE76 colour distance for both so
a "the highlighting looks subtle" report can be separated from a renderer bug.

Usage:
    python tools/theme_contrast.py \
        --theme cool-light=path/to/style_cool_light_generated.odin \
        --theme warm=path/to/style_paper_generated.odin \
        --md-out report.md --json-out report.json
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys

TOKEN = re.compile(
    r"result\.color_tokens\[(\d+)\] = alicorn\.Color\{([^}]*)\}"
)
PROVENANCE = re.compile(
    r'result\.color_token_provenance\[(\d+)\] = '
    r'alicorn\.Style_Token_Provenance\{id=(\d+), name="([^"]*)", '
    r'alias_target="([^"]*)"\}'
)
CLASSES = ["keyword", "function", "string", "comment", "number", "type", "constant", "variable"]


def parse_style(path):
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    colors = {}
    for match in TOKEN.finditer(source):
        index = int(match.group(1))
        components = [float(value) for value in match.group(2).split(",")]
        colors[index] = tuple(components[:3])
    tokens = {}
    for match in PROVENANCE.finditer(source):
        index = int(match.group(1))
        name = match.group(3)
        if index in colors:
            tokens[name] = colors[index]
    if not tokens:
        raise SystemExit(f"theme_contrast: no tokens parsed from {path}")
    return tokens


def stored_to_displayed(channel):
    """The rendered sRGB code value: stored linear channel written unchanged."""
    return min(255, max(0, round(channel * 255)))


def stored_to_authored(channel):
    """The authored sRGB code value recovered from the stored linear channel."""
    if channel <= 0.0031308:
        encoded = 12.92 * channel
    else:
        encoded = 1.055 * (channel ** (1 / 2.4)) - 0.055
    return min(255, max(0, round(encoded * 255)))


def relative_luminance(rgb):
    channels = []
    for value in rgb:
        code = value / 255.0
        channels.append(code / 12.92 if code <= 0.04045 else ((code + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast_ratio(a, b):
    high = max(relative_luminance(a), relative_luminance(b))
    low = min(relative_luminance(a), relative_luminance(b))
    return (high + 0.05) / (low + 0.05)


def linear_rgb_to_xyz(rgb):
    channels = []
    for value in rgb:
        code = value / 255.0
        channels.append(code / 12.92 if code <= 0.04045 else ((code + 0.055) / 1.055) ** 2.4)
    r, g, b = channels
    x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    return x, y, z


def lab(rgb):
    x, y, z = linear_rgb_to_xyz(rgb)
    xn, yn, zn = 0.95047, 1.0, 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else (7.787 * t) + (16 / 116)

    fx, fy, fz = f(x / xn), f(y / yn), f(z / zn)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def delta_e(a, b):
    la, aa, ba = lab(a)
    lb, ab, bb = lab(b)
    return math.sqrt((la - lb) ** 2 + (aa - ab) ** 2 + (ba - bb) ** 2)


def hex_of(rgb):
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def resolve(tokens, suffix, namespace=None):
    matches = [
        (name, rgb)
        for name, rgb in tokens.items()
        if name.endswith(suffix) and not name.startswith("alicorn.")
    ]
    if namespace:
        preferred = [(name, rgb) for name, rgb in matches if name.startswith(namespace + ".")]
        if preferred:
            return preferred[0]
    return matches[0] if matches else (None, None)


def analyse(tokens, name):
    background_name, background = resolve(tokens, ".editor_background")
    if background is None:
        background_name, background = resolve(tokens, ".paper_surface")
    if background is None:
        raise SystemExit(f"theme_contrast: {name}: no editor background token")
    namespace = background_name.rsplit(".", 1)[0]
    text_name, text = resolve(tokens, ".text", namespace)
    if text is None:
        text_name, text = resolve(tokens, ".text")
    muted_name, muted = resolve(tokens, ".muted_text", namespace)

    def displayed(rgb):
        return tuple(stored_to_displayed(channel) for channel in rgb)

    def authored(rgb):
        return tuple(stored_to_authored(channel) for channel in rgb)

    # Most editor text is unclassified identifiers, which Scratchpad paints with
    # the syntax `variable` role. That role is the real visual baseline for
    # "does highlighting stand out from plain text", so report against it too.
    baseline_name, baseline = resolve(tokens, ".syntax.variable")
    if baseline is None:
        baseline_name, baseline = text_name, text

    background_d, background_a = displayed(background), authored(background)
    text_d, text_a = displayed(text), authored(text)
    baseline_d = displayed(baseline)
    baseline_a = authored(baseline)
    muted_d = displayed(muted) if muted else None

    rows = []
    for token_class in CLASSES:
        token_name, token = resolve(tokens, f".syntax.{token_class}")
        if token is None:
            continue
        token_d, token_a = displayed(token), authored(token)
        rows.append(
            {
                "class": token_class,
                "token": token_name,
                "storage_linear": [round(channel, 6) for channel in token],
                "displayed_hex": hex_of(token_d),
                "authored_hex": hex_of(token_a),
                "displayed_luminance": round(relative_luminance(token_d), 5),
                "displayed_vs_background": round(contrast_ratio(token_d, background_d), 2),
                "displayed_vs_text": round(contrast_ratio(token_d, text_d), 2),
                "displayed_vs_baseline": round(contrast_ratio(token_d, baseline_d), 2),
                "displayed_delta_e_vs_baseline": round(delta_e(token_d, baseline_d), 1),
                "authored_vs_background": round(contrast_ratio(token_a, background_a), 2),
                "authored_vs_text": round(contrast_ratio(token_a, text_a), 2),
                "authored_vs_baseline": round(contrast_ratio(token_a, baseline_a), 2),
                "authored_delta_e_vs_baseline": round(delta_e(token_a, baseline_a), 1),
                # Projection for "pre-compensate the syntax palette, leave plain
                # text alone": the stored channel becomes the authored sRGB code,
                # so the token displays as `authored_hex` against today's
                # background and today's plain-text baseline.
                "precomp_vs_background": round(contrast_ratio(token_a, background_d), 2),
                "precomp_vs_baseline": round(contrast_ratio(token_a, baseline_d), 2),
                "precomp_delta_e_vs_baseline": round(delta_e(token_a, baseline_d), 1),
            }
        )
    return {
        "theme": name,
        "background_token": background_name,
        "text_token": text_name,
        "muted_token": muted_name,
        "baseline_token": baseline_name,
        "displayed": {
            "background_hex": hex_of(background_d),
            "text_hex": hex_of(text_d),
            "muted_hex": hex_of(muted_d) if muted_d else None,
            "baseline_hex": hex_of(baseline_d),
            "text_vs_background": round(contrast_ratio(text_d, background_d), 2),
            "baseline_vs_background": round(contrast_ratio(baseline_d, background_d), 2),
            "muted_vs_background": round(contrast_ratio(muted_d, background_d), 2) if muted_d else None,
        },
        "authored": {
            "background_hex": hex_of(background_a),
            "text_hex": hex_of(text_a),
            "muted_hex": hex_of(authored(muted)) if muted else None,
            "text_vs_background": round(contrast_ratio(text_a, background_a), 2),
            "muted_vs_background": round(contrast_ratio(authored(muted), background_a), 2) if muted else None,
        },
        "tokens": rows,
    }


def markdown(reports):
    lines = []
    lines += [
        "# Syntax token contrast in generated themes",
        "",
        "Stored channels are linear-sRGB and both hosts write them unchanged into a",
        "non-sRGB swapchain, so **displayed** is what the user sees and **authored**",
        "is the design intent recovered by sRGB-encoding the stored value.",
        "",
    ]
    for report in reports:
        background = report["displayed"]["background_hex"]
        text = report["displayed"]["text_hex"]
        baseline = report["displayed"]["baseline_hex"]
        lines += [
            f"## {report['theme']}",
            "",
            f"Editor background `{background}`, body text `{text}` "
            f"({report['displayed']['text_vs_background']}:1 text contrast), "
            f"editor baseline (syntax `variable`) `{baseline}`. "
            f"Authored intent `{report['authored']['background_hex']}` / `{report['authored']['text_hex']}` "
            f"({report['authored']['text_vs_background']}:1).",
            "",
            "| Token | Displayed | vs background | vs editor baseline | dE vs baseline | Authored | vs background (intent) | vs baseline (intent) | dE vs baseline (intent) |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for row in report["tokens"]:
            lines.append(
                "| {cls} | `{d}` | {dbg:.2f}:1 | {dbase:.2f}:1 | {de:.1f} | `{a}` | {abg:.2f}:1 | {abase:.2f}:1 | {ade:.1f} |".format(
                    cls=row["class"],
                    d=row["displayed_hex"],
                    dbg=row["displayed_vs_background"],
                    dbase=row["displayed_vs_baseline"],
                    de=row["displayed_delta_e_vs_baseline"],
                    a=row["authored_hex"],
                    abg=row["authored_vs_background"],
                    abase=row["authored_vs_baseline"],
                    ade=row["authored_delta_e_vs_baseline"],
                )
            )
        lines += [
            "",
            "Pre-compensated projection (syntax tokens only; plain text unchanged):",
            "",
            "| Token | Displays as | vs background | vs editor baseline | dE vs baseline |",
            "| --- | --- | --- | --- | --- |",
        ]
        for row in report["tokens"]:
            lines.append(
                "| {cls} | `{d}` | {dbg:.2f}:1 | {dbase:.2f}:1 | {de:.1f} |".format(
                    cls=row["class"],
                    d=row["authored_hex"],
                    dbg=row["precomp_vs_background"],
                    dbase=row["precomp_vs_baseline"],
                    de=row["precomp_delta_e_vs_baseline"],
                )
            )
        lines.append("")
    return "\n".join(lines)


def main(argv):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--theme",
        action="append",
        required=True,
        help="name=path to a generated style file (repeatable)",
    )
    parser.add_argument("--json-out")
    parser.add_argument("--md-out")
    options = parser.parse_args(argv)

    reports = []
    for entry in options.theme:
        name, _, path = entry.partition("=")
        if not path:
            raise SystemExit("theme_contrast: --theme expects name=path")
        reports.append(analyse(parse_style(path), name))

    if options.json_out:
        with open(options.json_out, "w", encoding="utf-8") as handle:
            json.dump({"themes": reports}, handle, indent=2)
            handle.write("\n")
    document = markdown(reports)
    if options.md_out:
        with open(options.md_out, "w", encoding="utf-8") as handle:
            handle.write(document if document.endswith("\n") else document + "\n")
    print(document)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
