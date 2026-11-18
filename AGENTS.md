# Agent guidance

Alicorn is a native GUI runtime for Odin. Start with
[docs/development.md](docs/development.md) for the repository map, build and
test entry points, and change boundaries. Author UI against
[docs/guide.md](docs/guide.md) and [docs/reference.md](docs/reference.md).

## Layout scopes

`ui.row`, `ui.column`, `ui.panel`, and other deferred-scope helpers must be
invoked directly in the block that describes their children. Do not wrap their
opening calls in procedures or describe children after the invocation block.

These helpers open an `@(deferred_in_out)` scope that closes at the end of the
invocation block, not at the end of the enclosing procedure. The compiler accepts
the wrapped form, but the children then lay out as siblings in the parent and a
padded fit-content container measures padding only. The
[#206 research record](docs/research/issue-206-fit-content-panel.md) has the
full evidence.

## Checks

Run `.\tools\test.ps1` on Windows or `./tools/test.sh` on Unix-like systems
before proposing changes. Update the relevant docs and regression fixtures with
behavior changes.
