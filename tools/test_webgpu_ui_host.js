"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function makeHost(options = {}) {
	const listeners = new Map();
	const schedulerCalls = { wake: 0, visible: [], dispose: 0 };
	let shutdownCalls = 0;
	let shutdownCompletes = true;
	let browserStatus = 1;
	let failureCode = 0;
	let nextWakeNs = 0n;
	let frameCalls = 0;
	let scheduler;
	let wgpuInterface;
	let wasmMemoryInterface;
	let clipboardLive = true;
	const clipboardCompletions = [];
	const clipboardBufferPointer = 1024;
	const statusElement = { textContent: "" };
	const exports = {
		default_context_ptr: () => 7,
		_start: () => {},
		alicorn_browser_status: () => browserStatus,
		alicorn_browser_failure_code: () => failureCode,
		alicorn_browser_frame: () => {
			frameCalls++;
			if (browserStatus === 3) {
				if (shutdownCompletes) {
					shutdownCalls++;
					browserStatus = -2;
				}
			}
			return false;
		},
		alicorn_browser_next_wake_ns: () => nextWakeNs,
		alicorn_browser_resize: () => 0,
		alicorn_browser_clipboard_read_buffer: (_context, _token, _length) => clipboardLive ? clipboardBufferPointer : 0,
		alicorn_browser_clipboard_complete: (_context, token, result, byteLength) => {
			if (!clipboardLive) return;
			const text = result === 0 && byteLength > 0
				? new TextDecoder().decode(new Uint8Array(wasmMemoryInterface.memory.buffer, clipboardBufferPointer, byteLength))
				: "";
			clipboardCompletions.push({ token, result, byteLength, text });
		},
		alicorn_browser_shutdown: () => {
			shutdownCalls++;
			browserStatus = shutdownCompletes ? -2 : 3;
			return shutdownCompletes;
		},
	};
	class FakeScheduler {
		constructor(options) { this.options = options; scheduler = this; }
		wake() { schedulerCalls.wake++; }
		setVisible(visible) { schedulerCalls.visible.push(visible); }
		dispose() { schedulerCalls.dispose++; }
		runFrame(nowNs) { return this.options.runFrame(nowNs); }
	}
	class FakeMemoryInterface {
		constructor() { this.memory = { buffer: new ArrayBuffer(2 * 1024 * 1024) }; wasmMemoryInterface = this; }
		setIntSize() {}
		setExports() {}
		setMemory() {}
		loadBytes(pointer, length) { return new Uint8Array(this.memory.buffer, pointer, Number(length)); }
		loadString(pointer, length) { return new TextDecoder().decode(this.loadBytes(pointer, length)); }
	}
	class FakeWebGPUInterface {
		constructor(wasmMemoryInterface) { wgpuInterface = this; this.wasmMemoryInterface = wasmMemoryInterface; }
		getInterface() { return {}; }
		callCallback(callback, args) { callback(...args); }
	}
	const root = {
		isSecureContext: true,
		navigator: { gpu: {}, clipboard: Object.prototype.hasOwnProperty.call(options, "clipboard") ? options.clipboard : {
			readText: async () => "",
			writeText: async () => {},
		} },
		document: {
			hidden: false,
			getElementById: id => id === "alicorn-canvas" ? {} : null,
			addEventListener: () => {},
		},
		odin: {
			WasmMemoryInterface: FakeMemoryInterface,
			WebGPUInterface: FakeWebGPUInterface,
			setupDefaultImports: () => ({}),
		},
		AlicornDemandScheduler: FakeScheduler,
		fetch: async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(0) }),
		WebAssembly: { instantiate: async () => ({ instance: { exports } }) },
		TextEncoder,
		TextDecoder,
		Uint8Array,
		console: { error: () => {} },
		addEventListener: (name, callback) => listeners.set(name, callback),
	};
	vm.runInNewContext(fs.readFileSync("host/web/webgpu_ui_host.js", "utf8"), root);
	await root.AlicornWebGPUHost.start("app.wasm", { statusElement });
	return {
		root,
		clipboard: root.__alicornWebGPUClipboard,
		clipboardCompletions,
		memoryInterface: wasmMemoryInterface,
		setClipboardLive: value => { clipboardLive = value; },
		listeners,
		schedulerCalls,
		setDocumentHidden: value => { root.document.hidden = value; },
		setShutdownCompletes: value => { shutdownCompletes = value; },
		setBrowserStatus: value => { browserStatus = value; },
		setFailureCode: value => { failureCode = value; },
		setNextWakeNs: value => { nextWakeNs = BigInt(value); },
		shutdownCalls: () => shutdownCalls,
		frameCalls: () => frameCalls,
		statusText: () => statusElement.textContent,
		callGpuCallback: () => wgpuInterface.callCallback(() => {}, []),
		runFrame: nowNs => scheduler.runFrame(nowNs),
	};
}

async function testBrowserClipboardReadsAndWritesUnicodeText() {
	let written = null;
	const host = await makeHost({ clipboard: {
		readText: async () => "Copied from browser 🐉",
		writeText: async text => { written = text; },
	} });
	host.clipboard.readText(11);
	for (let count = 0; count < 5 && host.clipboardCompletions.length === 0; count++) await Promise.resolve();
	assert.deepEqual(host.clipboardCompletions, [{
		token: 11,
		result: 0,
		byteLength: new TextEncoder().encode("Copied from browser 🐉").length,
		text: "Copied from browser 🐉",
	}]);

	const outgoing = "Clipboard write 🦊";
	const encoded = new TextEncoder().encode(outgoing);
	host.memoryInterface.loadBytes(256, encoded.length).set(encoded);
	host.clipboard.writeText(12, 256, encoded.length);
	for (let count = 0; count < 5 && host.clipboardCompletions.length < 2; count++) await Promise.resolve();
	assert.equal(written, outgoing, "writeText decodes Odin's UTF-8 bytes before calling the browser API");
	assert.equal(host.clipboardCompletions[1].result, 0);
	assert.equal(host.clipboardCompletions[1].token, 12);
}

async function testBrowserClipboardReportsPermissionAndUnsupportedResults() {
	const denied = await makeHost({ clipboard: {
		readText: async () => { const error = new Error("permission"); error.name = "NotAllowedError"; throw error; },
		writeText: async () => {},
	} });
	denied.clipboard.readText(21);
	for (let count = 0; count < 5 && denied.clipboardCompletions.length === 0; count++) await Promise.resolve();
	assert.equal(denied.clipboardCompletions[0].result, 2, "browser permission denial has a distinct result");

	const unsupported = await makeHost({ clipboard: undefined });
	unsupported.clipboard.readText(22);
	assert.equal(unsupported.clipboardCompletions[0].result, 1, "missing browser API is reported as unsupported");
	const noClipboard = await makeHost({ clipboard: null });
	noClipboard.clipboard.readText(23);
	assert.equal(noClipboard.clipboardCompletions[0].result, 1);
}

async function testBrowserClipboardBoundsReadsAndIgnoresLateSettlement() {
	const oversized = await makeHost({ clipboard: { readText: async () => "x".repeat(1024 * 1024 + 8) } });
	oversized.clipboard.readText(31);
	for (let count = 0; count < 5 && oversized.clipboardCompletions.length === 0; count++) await Promise.resolve();
	assert.equal(oversized.clipboardCompletions[0].result, 4, "large clipboard reads are rejected before WASM allocation");

	let resolveRead;
	const late = await makeHost({ clipboard: { readText: () => new Promise(resolve => { resolveRead = resolve; }) } });
	late.clipboard.readText(32);
	late.setClipboardLive(false);
	resolveRead("late result");
	for (let count = 0; count < 5; count++) await Promise.resolve();
	assert.equal(late.clipboardCompletions.length, 0, "a settled promise after host teardown is ignored");
}

async function testWebGPUStartupExplainsUnavailableCapabilitiesBeforeLoadingWasm() {
	const source = fs.readFileSync("host/web/webgpu_ui_host.js", "utf8");
	for (const testCase of [
		{
			name: "insecure context",
			root: { isSecureContext: false, navigator: { gpu: {} } },
			message: /secure context.*HTTPS or localhost/,
		},
		{
			name: "browser without WebGPU",
			root: { isSecureContext: true, navigator: {} },
			message: /does not expose WebGPU/,
		},
	]) {
		let fetchCalls = 0;
		const root = {
			...testCase.root,
			fetch: async () => { fetchCalls++; throw new Error("WASM must not load"); },
		};
		vm.runInNewContext(source, root);
		await assert.rejects(root.AlicornWebGPUHost.start("app.wasm"), testCase.message, testCase.name);
		assert.equal(fetchCalls, 0, `${testCase.name} must fail before downloading WASM`);
	}
}

async function testRecoveryUsesBoundedLifecycleFramesAndReportsOutcome() {
	const host = await makeHost();
	host.setBrowserStatus(4);
	const recovery = host.runFrame(5_000_000n);
	assert.equal(host.frameCalls(), 1, "recovery status advances the Odin lifecycle without regular UI frames");
	assert.equal(recovery.hasMoreWork, false, "recovery waits for callbacks instead of polling");
	assert.equal(host.statusText().includes("preserving retained UI state"), true);

	host.setNextWakeNs(1_000_000_000n);
	const retry = host.runFrame(10_000_000n);
	assert.equal(retry.nextWakeNs, 1_000_000_000n, "bounded retry deadline is handed to the demand scheduler");
	assert.equal(retry.notifyIdle, false);

	host.setBrowserStatus(1);
	host.runFrame(1_000_000_000n);
	assert.equal(host.statusText(), "WebGPU UI ready. Resize, click, or type to exercise the retained host.");

	host.setBrowserStatus(-3);
	host.runFrame(1_100_000_000n);
	assert.equal(host.statusText().includes("Reload the page"), true, "failed recovery asks for a reload");
}

async function testAdapterFailureShowsActionableStatus() {
	const host = await makeHost();
	host.setBrowserStatus(-1);
	for (const [code, expected] of [
		[1, /could not create an instance/],
		[2, /presentation surface for this canvas/],
		[3, /No compatible WebGPU adapter.*drivers.*permissions/],
		[4, /failed to request a WebGPU adapter/],
		[5, /does not support presenting WebGPU/],
		[6, /could not create a WebGPU device/],
		[7, /did not provide a submission queue/],
		[8, /could not initialize its WebGPU renderer/],
	]) {
		host.setFailureCode(code);
		host.runFrame(1_000_000n + BigInt(code));
		assert.match(host.statusText(), expected, `failure code ${code} should have specific guidance`);
	}
}

async function testBackForwardCacheSuspendsAndResumesExistingHost() {
	const host = await makeHost();
	host.listeners.get("pagehide")({ persisted: true });
	assert.deepEqual(host.schedulerCalls.visible, [false]);
	assert.equal(host.shutdownCalls(), 0, "bfcache entry must retain the WebGPU host");
	assert.equal(host.schedulerCalls.dispose, 0, "bfcache entry must retain its scheduler");
	host.setDocumentHidden(false);
	host.listeners.get("pageshow")({ persisted: true });
	assert.deepEqual(host.schedulerCalls.visible, [false, true]);
	assert.equal(host.shutdownCalls(), 0, "pageshow must resume the existing host");
}

async function testOrdinaryPagehideRequestsShutdown() {
	const host = await makeHost();
	host.listeners.get("pagehide")({ persisted: false });
	assert.equal(host.shutdownCalls(), 1);
	assert.equal(host.schedulerCalls.dispose, 1, "completed shutdown disposes the scheduler");
	host.listeners.get("pageshow")({ persisted: true });
	assert.deepEqual(host.schedulerCalls.visible, [], "disposed page must not revive its scheduler");
}

async function testPendingShutdownRetriesAfterGpuCompletionWake() {
	const host = await makeHost();
	host.setShutdownCompletes(false);
	host.listeners.get("pagehide")({ persisted: false });
	assert.equal(host.shutdownCalls(), 1);
	assert.equal(host.schedulerCalls.dispose, 0, "pending shutdown must retain the scheduler");
	host.callGpuCallback();
	assert.equal(host.schedulerCalls.wake, 2, "GPU callback wakes the pending shutdown retry");
	host.setShutdownCompletes(true);
	host.runFrame(0n);
	assert.equal(host.shutdownCalls(), 2, "next scheduled frame retries WebGPU teardown");
	assert.equal(host.schedulerCalls.dispose, 1, "completed retry disposes the scheduler");
}

(async () => {
	for (const test of [
		testWebGPUStartupExplainsUnavailableCapabilitiesBeforeLoadingWasm,
		testBrowserClipboardReadsAndWritesUnicodeText,
		testBrowserClipboardReportsPermissionAndUnsupportedResults,
		testBrowserClipboardBoundsReadsAndIgnoresLateSettlement,
		testAdapterFailureShowsActionableStatus,
		testRecoveryUsesBoundedLifecycleFramesAndReportsOutcome,
		testBackForwardCacheSuspendsAndResumesExistingHost,
		testOrdinaryPagehideRequestsShutdown,
		testPendingShutdownRetriesAfterGpuCompletionWake,
	]) {
		await test();
		console.log(`PASS ${test.name}`);
	}
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
