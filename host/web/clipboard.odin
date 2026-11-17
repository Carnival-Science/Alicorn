#+build js wasm32, js wasm64p32

package web_host

import "core:fmt"
import "core:mem"
import "core:sys/wasm/js"
import clipboard "alicorn:host/clipboard"

Browser_Clipboard_Max_Pending :: 8
Browser_Clipboard_Max_Bytes :: 1024 * 1024

@(private)
Browser_Clipboard_Request :: struct {
	token: u32,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
	read_buffer: []byte,
}

// Browser_Clipboard owns bounded asynchronous requests until the JS Clipboard
// API settles or the WebGPU host begins shutdown. Promise callbacks return to
// the browser's main thread, which is also the Hosted_Runtime owner thread.
Browser_Clipboard :: struct {
	allocator: mem.Allocator,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	requests: [Browser_Clipboard_Max_Pending]Browser_Clipboard_Request,
	next_token: u32,
	active: bool,
	closed: bool,
}

browser_webgpu_run_clipboard_service :: proc(host: ^Browser_WebGPU_Run) -> clipboard.Clipboard_Service {
	if host == nil || !host.initialized || host.destroy_requested { return {} }
	state := &host.clipboard
	if !state.active {
		state^ = Browser_Clipboard{
			allocator=host.ctx.allocator,
			wake_data=host.wake_data,
			wake=host.wake,
			next_token=1,
			active=true,
		}
	}
	if state.closed { return {} }
	return clipboard.Clipboard_Service{
		data=rawptr(state),
		read_text=browser_clipboard_read_text,
		write_text=browser_clipboard_write_text,
	}
}

browser_clipboard_read_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	state := cast(^Browser_Clipboard)data
	if state == nil || completion == nil || !state.active || state.closed { return false }
	request := browser_clipboard_request_begin(state, request_id, completion_data, completion)
	if request == nil { return false }
	js.evaluate(fmt.tprintf("globalThis.__alicornWebGPUClipboard.readText(%d)", request.token))
	return true
}

browser_clipboard_write_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	state := cast(^Browser_Clipboard)data
	if state == nil || completion == nil || !state.active || state.closed { return false }
	request := browser_clipboard_request_begin(state, request_id, completion_data, completion)
	if request == nil { return false }
	if len(text) > Browser_Clipboard_Max_Bytes {
		browser_clipboard_complete_state(state, request.token, .Too_Large, 0)
		return true
	}
	text_ptr: u32
	if len(text) > 0 { text_ptr = u32(uintptr(raw_data(text))) }
	js.evaluate(fmt.tprintf(
		"globalThis.__alicornWebGPUClipboard.writeText(%d,%d,%d)",
		request.token,
		text_ptr,
		len(text),
	))
	return true
}

@(private)
browser_clipboard_request_begin :: proc(
	state: ^Browser_Clipboard,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> ^Browser_Clipboard_Request {
	if state == nil || state.closed { return nil }
	for index in 0..<len(state.requests) {
		request := &state.requests[index]
		if request.completion != nil { continue }
		request^ = Browser_Clipboard_Request{
			token=browser_clipboard_next_token(state),
			request_id=request_id,
			completion_data=completion_data,
			completion=completion,
		}
		return request
	}
	return nil
}

@(private)
browser_clipboard_next_token :: proc(state: ^Browser_Clipboard) -> u32 {
	for {
		token := state.next_token
		state.next_token += 1
		if state.next_token == 0 { state.next_token = 1 }
		if token == 0 { continue }
		used := false
		for request in state.requests {
			if request.completion != nil && request.token == token {
				used = true
				break
			}
		}
		if !used { return token }
	}
}

@(private)
browser_clipboard_request_find :: proc(state: ^Browser_Clipboard, token: u32) -> ^Browser_Clipboard_Request {
	if state == nil || token == 0 { return nil }
	for index in 0..<len(state.requests) {
		request := &state.requests[index]
		if request.completion != nil && request.token == token { return request }
	}
	return nil
}

// browser_webgpu_run_clipboard_read_buffer is called only after a read promise
// resolves. The returned memory remains owned by this request until completion.
browser_webgpu_run_clipboard_read_buffer :: proc(host: ^Browser_WebGPU_Run, token: u32, byte_length: u32) -> u32 {
	if host == nil { return 0 }
	state := &host.clipboard
	if !state.active || state.closed || byte_length == 0 || byte_length > Browser_Clipboard_Max_Bytes { return 0 }
	request := browser_clipboard_request_find(state, token)
	if request == nil || len(request.read_buffer) != 0 { return 0 }
	buffer, err := mem.alloc_bytes(int(byte_length), allocator=state.allocator)
	if err != .None || len(buffer) != int(byte_length) { return 0 }
	request.read_buffer = buffer
	return u32(uintptr(rawptr(&request.read_buffer[0])))
}

// browser_webgpu_run_clipboard_complete is a bounded, stale-token-safe promise
// completion entry point. result_code is the ordinal in Clipboard_Result.
browser_webgpu_run_clipboard_complete :: proc(host: ^Browser_WebGPU_Run, token: u32, result_code: u32, byte_length: u32) {
	if host == nil { return }
	context = host.ctx
	state := &host.clipboard
	if !state.active { return }
	result := clipboard.Clipboard_Result(result_code)
	if result_code > u32(clipboard.Clipboard_Result.Failed) { result = .Failed }
	browser_clipboard_complete_state(state, token, result, int(byte_length))
}

@(private)
browser_clipboard_complete_state :: proc(
	state: ^Browser_Clipboard,
	token: u32,
	result: clipboard.Clipboard_Result,
	byte_length: int,
) {
	request := browser_clipboard_request_find(state, token)
	if request == nil { return }
	completed := request^
	request^ = {}
	completion_result := result
	if completion_result == .Success && (byte_length < 0 || byte_length > len(completed.read_buffer)) {
		completion_result = .Failed
	}
	text := ""
	if completion_result == .Success && byte_length > 0 { text = string(completed.read_buffer[:byte_length]) }
	if completed.completion != nil {
		completed.completion(completed.completion_data, completed.request_id, completion_result, text)
	}
	if !state.closed && state.wake != nil { state.wake(state.wake_data) }
	if len(completed.read_buffer) > 0 {
		_ = mem.free_with_size(rawptr(&completed.read_buffer[0]), len(completed.read_buffer), allocator=state.allocator)
	}
}

browser_clipboard_close :: proc(state: ^Browser_Clipboard) {
	if state == nil || !state.active || state.closed { return }
	state.closed = true
	for index in 0..<len(state.requests) {
		request := &state.requests[index]
		if request.completion != nil {
			browser_clipboard_complete_state(state, request.token, .Cancelled, 0)
		}
	}
}
