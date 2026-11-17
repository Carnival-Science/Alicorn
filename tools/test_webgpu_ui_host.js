"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function makeHost() {
	const listeners = new Map();
	const schedulerCalls = { wake: 0, visible: [], dispose: 0 };
	let shutdownCalls = 0;
	let shutdownCompletes = true;
	let browserStatus = 1;
	let nextWakeNs = 0n;
	let frameCalls = 0;
	let scheduler;
	let wgpuInterface;
	const statusElement = { textContent: "" };
	const exports = {
		default_context_ptr: () => 7,
		_start: () => {},
		alicorn_browser_status: () => browserStatus,
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
		constructor() { this.memory = {}; }
		setIntSize() {}
		setExports() {}
		setMemory() {}
	}
	class FakeWebGPUInterface {
		constructor() { wgpuInterface = this; }
		getInterface() { return {}; }
		callCallback(callback, args) { callback(...args); }
	}
	const root = {
		navigator: { gpu: {} },
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
		console: { error: () => {} },
		addEventListener: (name, callback) => listeners.set(name, callback),
	};
	vm.runInNewContext(fs.readFileSync("host/web/webgpu_ui_host.js", "utf8"), root);
	await root.AlicornWebGPUHost.start("app.wasm", { statusElement });
	return {
		listeners,
		schedulerCalls,
		setDocumentHidden: value => { root.document.hidden = value; },
		setShutdownCompletes: value => { shutdownCompletes = value; },
		setBrowserStatus: value => { browserStatus = value; },
		setNextWakeNs: value => { nextWakeNs = BigInt(value); },
		shutdownCalls: () => shutdownCalls,
		frameCalls: () => frameCalls,
		statusText: () => statusElement.textContent,
		callGpuCallback: () => wgpuInterface.callCallback(() => {}, []),
		runFrame: nowNs => scheduler.runFrame(nowNs),
	};
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
