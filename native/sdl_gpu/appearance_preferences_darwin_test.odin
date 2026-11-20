#+build darwin

package alicorn_sdl_gpu

import "core:sync"
import "core:testing"

@(test)
test_darwin_appearance_notification_refreshes_every_window_monitor :: proc(t: ^testing.T) {
	first, second: Native_Appearance_Monitor
	sync.atomic_store(&first.active, 1)
	sync.atomic_store(&second.active, 1)

	service := Darwin_Appearance_Service{
		monitors=make([dynamic]^Native_Appearance_Monitor, 0, allocator=context.temp_allocator),
	}
	defer delete(service.monitors)
	_, first_error := append(&service.monitors, &first)
	_, second_error := append(&service.monitors, &second)
	if first_error != nil || second_error != nil {
		testing.expect(t, false, "the shared appearance service should hold both window monitors")
		return
	}

	darwin_appearance_service_request_refresh(&service)
	first_pending := sync.atomic_load(&first.refresh_pending) != 0
	second_pending := sync.atomic_load(&second.refresh_pending) != 0
	testing.expect(t, first_pending && second_pending,
		"one process-wide appearance notification should schedule a refresh for every live window")
}
