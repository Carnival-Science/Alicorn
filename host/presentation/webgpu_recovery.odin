package presentation_host

import "vendor:wgpu"

// Device reacquisition starts immediately after loss, then allows three
// bounded retries. Both SDL3 and browser hosts use the same backoff policy.
WEBGPU_RECOVERY_BACKOFF_NS :: [3]u64{250_000_000, 1_000_000_000, 2_000_000_000}
WEBGPU_RECOVERY_MAX_ATTEMPTS :: len(WEBGPU_RECOVERY_BACKOFF_NS) + 1

// Explicit DeviceDestroy and a cancelled callback are lifecycle outcomes, not
// evidence of driver/OS loss. Hosts must not enter automatic recovery for
// either reason. Other reasons use the bounded recovery policy; that policy
// decision is not itself evidence that the OS or driver caused the loss.
webgpu_device_loss_should_recover :: proc(reason: wgpu.DeviceLostReason) -> bool {
	return reason != .Destroyed && reason != .CallbackCancelled
}

WebGPU_Recovery_Policy :: struct {
	active: bool,
	failed: bool,
	attempt_pending: bool,
	attempts: int,
	retry_at_ns: u64,
}

webgpu_recovery_begin :: proc(policy: ^WebGPU_Recovery_Policy, now_ns: u64) {
	if policy == nil { return }
	policy^ = WebGPU_Recovery_Policy{active=true, retry_at_ns=now_ns}
}

webgpu_recovery_attempt_due :: proc(policy: ^WebGPU_Recovery_Policy, now_ns: u64) -> bool {
	return policy != nil && policy.active && !policy.failed && !policy.attempt_pending &&
		policy.attempts < WEBGPU_RECOVERY_MAX_ATTEMPTS && now_ns >= policy.retry_at_ns
}

webgpu_recovery_attempt_begin :: proc(policy: ^WebGPU_Recovery_Policy, now_ns: u64) -> bool {
	if !webgpu_recovery_attempt_due(policy, now_ns) { return false }
	policy.attempts += 1
	policy.attempt_pending = true
	return true
}

// Returns true when another bounded attempt is scheduled.
webgpu_recovery_attempt_failed :: proc(
	policy: ^WebGPU_Recovery_Policy,
	now_ns: u64,
) -> bool {
	if policy == nil || !policy.active || !policy.attempt_pending { return false }
	policy.attempt_pending = false
	if policy.attempts > len(WEBGPU_RECOVERY_BACKOFF_NS) {
		policy.active = false
		policy.failed = true
		policy.retry_at_ns = 0
		return false
	}
	backoff := WEBGPU_RECOVERY_BACKOFF_NS
	policy.retry_at_ns = now_ns + backoff[policy.attempts-1]
	return true
}

webgpu_recovery_succeed :: proc(policy: ^WebGPU_Recovery_Policy) {
	if policy == nil { return }
	policy^ = {}
}

webgpu_recovery_abort :: proc(policy: ^WebGPU_Recovery_Policy) {
	if policy == nil { return }
	policy^ = WebGPU_Recovery_Policy{failed=true}
}
