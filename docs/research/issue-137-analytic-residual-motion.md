# Issue #137 — analytic residual motion

**Status:** Core response math was already present on `master`; this pass
closes explicit cadence, long-stall, repeated-target, and documentation gaps.

**Reviewed:** 2026-11-16

## Decision and scope

[Issue #137](https://github.com/samanshaiza004/alicorn/issues/137) defines the
headless motion kernel in the order established by its parent
[#91](https://github.com/samanshaiza004/alicorn/issues/91): pure analytic math
and injected time first, followed by retained ownership, host scheduling, and
authoring. The current `master` already contains the scalar and 2D kernel in
[`runtime/motion_math.odin`](../../runtime/motion_math.odin), so this change
does not add a second motion implementation. It adds explicit acceptance
regressions and documents the behavior and its limits in the
[public reference](../reference.md).

## Contract confirmed in source

For a discrete, stationary target, let `r0 = P0 - T`, `v0` be the presented
initial velocity, and `omega > 0` be the critical response rate in reciprocal
seconds. The implementation evaluates the closed form at any supplied time,
without integrating frames:

```text
b      = v0 + omega*r0
R(t)   = (r0 + b*t) * exp(-omega*t)
P(t)   = T + R(t)
V(t)   = (v0 - omega*b*t) * exp(-omega*t)
```

`Motion_Time` is a signed nanosecond timestamp with an arbitrary monotonic
origin. Pure sampling accepts the timestamp as an argument; the retained
runtime also exposes an injected virtual clock for deterministic replay. The
math layer uses `f64` values and stores response state by value.

`motion_scalar_settle` and its 2D translation counterpart sample the existing
response at the target-change time, then use that presentation and velocity as
the next response's initial conditions. Reassigning the current `.Settle`
target returns the existing response unchanged. `.Direct` presents each
supplied target immediately with zero residual velocity; `.Snap` immediately
commits a discrete target. The model is critically damped only: it does not
define underdamped response or velocity handoff from a continuously moving
target.

Configuration validation requires finite positive `omega` and finite positive
position and velocity tolerances. Tolerances are measured in the animated
property's units, and both must be met before a response can retire. The code
computes conservative bounds for both position and velocity in log space,
brackets and bisects only in the monotone tail, and caps its supported horizon.
A response without a certified deadline remains active instead of being
prematurely snapped; retained scheduling has a separate bounded fallback for
that case. This is a conservative deadline, not an exact physical settlement
time.

The sampling path calls no allocator and has no frame-history state. The
existing Windows motion validation for [issue #146](../validation/issue-146-progress-2026-10-30.md)
also recorded zero allocations in active `motion_tick` sampling loops and in
1,000 retarget calls. That benchmark measures the retained runtime path, not a
standalone microbenchmark of `motion_scalar_sample`.

The tolerance policy is intentional. Odin documents `f16`, `f32`, and `f64`
floating-point types and permits some floating-point operations to be combined
so a result may differ from separately rounded operations. IEEE 754 specifies
floating-point formats and arithmetic behavior, but the Alicorn issue itself
sets the application-level replay requirement: compare within explicit numeric
tolerances rather than require bit-identical results across platform math
libraries. [Odin basic types and floating-point operators](https://odin-lang.org/docs/overview/#basic-types)
· [IEEE 754-2019 standard listing](https://standards.ieee.org/ieee/754/6210/)

## Acceptance coverage added

The pre-existing math tests already covered the closed-form position and
velocity, interrupted retarget continuity, long unsampled gaps, unchanged
target as a no-op, invalid inputs, extreme signed timestamps, uncertified
deadlines, and shared 2D settlement. This pass adds two explicit regressions in
[`runtime/motion_math_test.odin`](../../runtime/motion_math_test.odin):

- Compare equal-time samples after 30, 60, and 144 Hz intermediate sampling,
  including a deliberate 200 ms gap. The pure `f64` samples use an absolute
  comparison tolerance of `1e-10`; this is numerical replay, not a promise of
  bit-identical results from different platform `exp` implementations.
- Reassign the unchanged target 1,000 times for both scalar and 2D responses.
  Every response field must remain identical, and the later sampled value,
  velocity, and active state must not drift.

Validation on this checkout: `odin test runtime` passed all 355 tests. The
cadence regression uses deterministic timestamps and does not depend on a
native event loop or wall clock. Native rendering and host wake behavior are
covered by the broader motion work tracked by #91 and #146, not newly measured
by this kernel-focused pass.

## Primary sources

- [Issue #137 acceptance contract](https://github.com/samanshaiza004/alicorn/issues/137)
- [Parent motion architecture and implementation order (#91)](https://github.com/samanshaiza004/alicorn/issues/91)
- [`runtime/motion_math.odin`](../../runtime/motion_math.odin)
- [`runtime/motion_math_test.odin`](../../runtime/motion_math_test.odin)
- [`runtime/motion_replay_test.odin`](../../runtime/motion_replay_test.odin)
- [Issue #146 retained-motion benchmark and native validation](../validation/issue-146-progress-2026-10-30.md)
- [Odin language reference: basic types and floating-point operators](https://odin-lang.org/docs/overview/#basic-types)
- [IEEE 754-2019, IEEE Standard for Floating-Point Arithmetic](https://standards.ieee.org/ieee/754/6210/)
