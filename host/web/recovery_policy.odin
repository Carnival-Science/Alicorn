package web_host

// The initial adapter request is immediate. After a failed request, allow
// three bounded retries using these delays before reporting terminal failure.
BROWSER_WEBGPU_RECOVERY_BACKOFF_NS :: [3]u64{250_000_000, 1_000_000_000, 2_000_000_000}
BROWSER_WEBGPU_RECOVERY_MAX_ATTEMPTS :: len(BROWSER_WEBGPU_RECOVERY_BACKOFF_NS) + 1

Browser_WebGPU_Recovery_Policy :: struct {
	active: bool,
	failed: bool,
	attempt_pending: bool,
	attempts: int,
	retry_at_ns: u64,
}

browser_webgpu_recovery_begin :: proc(policy: ^Browser_WebGPU_Recovery_Policy, now_ns: u64) {
	if policy == nil { return }
	policy^ = Browser_WebGPU_Recovery_Policy{
		active=true,
		retry_at_ns=now_ns,
	}
}

browser_webgpu_recovery_attempt_due :: proc(policy: ^Browser_WebGPU_Recovery_Policy, now_ns: u64) -> bool {
	return policy != nil && policy.active && !policy.failed && !policy.attempt_pending &&
		policy.attempts < BROWSER_WEBGPU_RECOVERY_MAX_ATTEMPTS && now_ns >= policy.retry_at_ns
}

browser_webgpu_recovery_attempt_begin :: proc(policy: ^Browser_WebGPU_Recovery_Policy, now_ns: u64) -> bool {
	if !browser_webgpu_recovery_attempt_due(policy, now_ns) { return false }
	policy.attempts += 1
	policy.attempt_pending = true
	return true
}

// Returns true when another bounded attempt is scheduled.
browser_webgpu_recovery_attempt_failed :: proc(
	policy: ^Browser_WebGPU_Recovery_Policy,
	now_ns: u64,
) -> bool {
	if policy == nil || !policy.active || !policy.attempt_pending { return false }
	policy.attempt_pending = false
	if policy.attempts > len(BROWSER_WEBGPU_RECOVERY_BACKOFF_NS) {
		policy.active = false
		policy.failed = true
		policy.retry_at_ns = 0
		return false
	}
	backoff := BROWSER_WEBGPU_RECOVERY_BACKOFF_NS
	policy.retry_at_ns = now_ns + backoff[policy.attempts-1]
	return true
}

browser_webgpu_recovery_succeed :: proc(policy: ^Browser_WebGPU_Recovery_Policy) {
	if policy == nil { return }
	policy^ = {}
}

browser_webgpu_recovery_abort :: proc(policy: ^Browser_WebGPU_Recovery_Policy) {
	if policy == nil { return }
	policy^ = Browser_WebGPU_Recovery_Policy{failed=true}
}
