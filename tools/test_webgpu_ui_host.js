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
	let scheduler;
	let wgpuInterface;
	const exports = {
		default_context_ptr: () => 7,
		_start: () => {},
		alicorn_browser_status: () => browserStatus,
		alicorn_browser_frame: () => {
			if (browserStatus === 3) {
				if (shutdownCompletes) {
					shutdownCalls++;
					browserStatus = -2;
				}
			}
			return false;
		},
		alicorn_browser_next_wake_ns: () => 0n,
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
	await root.AlicornWebGPUHost.start("app.wasm");
	return {
		listeners,
		schedulerCalls,
		setDocumentHidden: value => { root.document.hidden = value; },
		setShutdownCompletes: value => { shutdownCompletes = value; },
		shutdownCalls: () => shutdownCalls,
		callGpuCallback: () => wgpuInterface.callCallback(() => {}, []),
		runFrame: nowNs => scheduler.runFrame(nowNs),
	};
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
