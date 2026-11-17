#+build !js

package presentation_host

import "core:testing"

@(test)
test_webgpu_recovery_policy_uses_all_bounded_backoffs :: proc(t: ^testing.T) {
	policy: WebGPU_Recovery_Policy
	webgpu_recovery_begin(&policy, 100)
	testing.expect(t, policy.active && !policy.failed && policy.retry_at_ns == 100)
	testing.expect(t, webgpu_recovery_attempt_due(&policy, 100))
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 100))
	testing.expect(t, !webgpu_recovery_attempt_due(&policy, 100), "a pending request cannot be duplicated")

	testing.expect(t, webgpu_recovery_attempt_failed(&policy, 200))
	testing.expect(t, policy.retry_at_ns == 250_000_200, "first retry uses 250 ms")
	testing.expect(t, !webgpu_recovery_attempt_due(&policy, 250_000_199))
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 250_000_200))
	testing.expect(t, webgpu_recovery_attempt_failed(&policy, 300_000_000))
	testing.expect(t, policy.retry_at_ns == 1_300_000_000, "second retry uses 1 s")
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 1_300_000_000))
	testing.expect(t, webgpu_recovery_attempt_failed(&policy, 1_400_000_000))
	testing.expect(t, policy.retry_at_ns == 3_400_000_000, "third retry uses 2 s")
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 3_400_000_000))
	testing.expect(t, !webgpu_recovery_attempt_failed(&policy, 3_500_000_000))
	testing.expect(t, !policy.active && policy.failed && policy.retry_at_ns == 0)
	testing.expect(t, !webgpu_recovery_attempt_begin(&policy, 10_000_000_000), "exhausted recovery does not retry forever")
}

@(test)
test_webgpu_recovery_policy_success_resets_for_a_later_loss :: proc(t: ^testing.T) {
	policy: WebGPU_Recovery_Policy
	webgpu_recovery_begin(&policy, 10)
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 10))
	webgpu_recovery_succeed(&policy)
	testing.expect(t, !policy.active && !policy.failed && policy.attempts == 0 && policy.retry_at_ns == 0)

	webgpu_recovery_begin(&policy, 20)
	testing.expect(t, webgpu_recovery_attempt_due(&policy, 20), "a later loss starts a fresh recovery budget")
	testing.expect(t, webgpu_recovery_attempt_begin(&policy, 20))
}
