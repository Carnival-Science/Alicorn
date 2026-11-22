#+build !js

package sdl3_host

import "core:dynlib"
import "core:fmt"
import "core:os"
import "vendor:sdl3"
import "vendor:wgpu"
import alicorn "alicorn:runtime"

// ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE enables the induced-backend-removal
// rung of the device-loss ladder. It is a validation build define, never a
// product feature: default builds compile every hook below to a no-op, and no
// native-device access reaches a shipped binary. The test-only wgpu-native
// export is resolved by name at run time so the production WebGPU binding and
// its C surface stay untouched.
//
// Evidence: docs/validation/webgpu-native-backend-removal-windows-2026-11-19.md
ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE :: #config(ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE, false)

when ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE {
	@(private)
	device_removal_request_ns: u64
	@(private)
	device_removal_issued_ns: u64

	@(private)
	sdl3_webgpu_run_d3d12_removal_requested :: proc() -> bool {
		for argument in os.args {
			if argument == "--test-remove-d3d12-device" { return true }
		}
		return false
	}

	// sdl3_webgpu_run_remove_d3d12_device_for_testing reaches the native
	// ID3D12Device behind the wgpu device through the test-only wgpu-native
	// export, removes it, then submits an empty command buffer. The submit is
	// the operation that observes the removal, which is how a real driver loss
	// surfaces; wgpu-core loses the device there and the registered DeviceLost
	// callback takes over recovery.
	@(private)
	sdl3_webgpu_run_remove_d3d12_device_for_testing :: proc(state: ^SDL3_WebGPU_Run_State) -> bool {
		if state == nil || state.device == nil || state.queue == nil { return false }
		library, loaded := dynlib.load_library("wgpu_native.dll")
		if !loaded {
			fmt.eprintln("[alicorn-webgpu] test removal: could not load wgpu_native.dll:", dynlib.last_error())
			return false
		}
		// The module is already resident and stays loaded for the process
		// lifetime; the device, not the library, is what this probe discards.
		symbol, found := dynlib.symbol_address(library, "wgpuDeviceRemoveD3D12ForTesting")
		if !found {
			fmt.eprintln(
				"[alicorn-webgpu] test removal: wgpu_native.dll has no wgpuDeviceRemoveD3D12ForTesting;",
				"rebuild it with dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch",
			)
			return false
		}
		remove_d3d12_device := cast(proc "c" (device: wgpu.Device) -> b32)symbol
		device_removal_issued_ns = u64(sdl3.GetTicksNS())
		removed := remove_d3d12_device(state.device)
		fmt.printf(
			"[alicorn-webgpu] test removal: ID3D12Device5::RemoveDevice issued=%v elapsed_ns=%d\n",
			removed,
			device_removal_issued_ns-device_removal_request_ns,
		)
		if !removed { return false }

		encoder := wgpu.DeviceCreateCommandEncoder(state.device)
		if encoder == nil { return false }
		command_buffer := wgpu.CommandEncoderFinish(encoder)
		if command_buffer != nil {
			wgpu.QueueSubmit(state.queue, {command_buffer})
			wgpu.CommandBufferRelease(command_buffer)
		}
		wgpu.CommandEncoderRelease(encoder)
		return true
	}

	@(private)
	sdl3_webgpu_run_test_mark_removal_request :: proc() {
		device_removal_request_ns = u64(sdl3.GetTicksNS())
	}

	@(private)
	sdl3_webgpu_run_test_trace :: proc(label: string) {
		if device_removal_issued_ns == 0 { return }
		fmt.printf(
			"[alicorn-webgpu] test removal trace: %s elapsed_ns=%d\n",
			label,
			u64(sdl3.GetTicksNS())-device_removal_issued_ns,
		)
	}

	// The motion trace records retained owner counts at the induced loss and
	// after reattachment, so a validation run can prove motion was live through
	// the loss rather than inferring it from adjacent fixture prints.
	@(private)
	sdl3_webgpu_run_test_trace_motion :: proc(application: ^SDL3_WebGPU_Application, label: string) {
		if device_removal_request_ns == 0 { return }
		active_owners := 0
		active_properties := 0
		if application != nil {
			if rt, status := alicorn.hosted_runtime_borrow(&application.hosted); status == .Ok && rt != nil {
				activity := alicorn.motion_activity(rt)
				active_owners = activity.active_owners
				active_properties = activity.active_properties
			}
		}
		fmt.printf(
			"[alicorn-webgpu] test removal trace: motion %s active_owners=%d active_properties=%d elapsed_ns=%d\n",
			label,
			active_owners,
			active_properties,
			u64(sdl3.GetTicksNS())-device_removal_request_ns,
		)
	}

	@(private)
	sdl3_webgpu_run_test_trace_loss :: proc(
		reason: wgpu.DeviceLostReason,
		message: wgpu.StringView,
	) {
		if device_removal_issued_ns == 0 { return }
		fmt.printf(
			"[alicorn-webgpu] test removal trace: device-lost callback fired reason=%v message=%s elapsed_ns=%d\n",
			reason,
			message,
			u64(sdl3.GetTicksNS())-device_removal_issued_ns,
		)
	}
} else {
	@(private)
	sdl3_webgpu_run_d3d12_removal_requested :: proc() -> bool { return false }

	@(private)
	sdl3_webgpu_run_remove_d3d12_device_for_testing :: proc(_: ^SDL3_WebGPU_Run_State) -> bool {
		return false
	}

	@(private)
	sdl3_webgpu_run_test_mark_removal_request :: proc() {}

	@(private)
	sdl3_webgpu_run_test_trace :: proc(_: string) {}

	@(private)
	sdl3_webgpu_run_test_trace_motion :: proc(_: ^SDL3_WebGPU_Application, _: string) {}

	@(private)
	sdl3_webgpu_run_test_trace_loss :: proc(
		_: wgpu.DeviceLostReason,
		_: wgpu.StringView,
	) {}
}
