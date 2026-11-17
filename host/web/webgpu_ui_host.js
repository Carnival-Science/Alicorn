(function (root) {
	"use strict";

	async function start(wasmUrl, options = {}) {
		if (!root.odin || !root.AlicornDemandScheduler) {
			throw new Error("Load Odin's wasm JavaScript and AlicornDemandScheduler before starting the app.");
		}
		if (!root.navigator.gpu) throw new Error("This browser does not expose WebGPU.");
		const memoryInterface = new root.odin.WasmMemoryInterface();
		memoryInterface.setIntSize(4);
		const wgpuInterface = new root.odin.WebGPUInterface(memoryInterface);
		const wgpuImports = wgpuInterface.getInterface();
		const imports = {
			...root.odin.setupDefaultImports(memoryInterface, null, memoryInterface.memory),
			wgpu: wgpuImports,
		};
		const response = await root.fetch(wasmUrl, { cache: "no-store" });
		if (!response.ok) throw new Error("WASM request failed: " + response.status);
		const { instance } = await root.WebAssembly.instantiate(await response.arrayBuffer(), imports);
		const exports = instance.exports;
		memoryInterface.setExports(exports);
		if (exports.memory) memoryInterface.setMemory(exports.memory);
		const context = exports.default_context_ptr();
		const status = options.statusElement || null;
		const readyMessage = "WebGPU UI ready. Resize, click, or type to exercise the retained host.";
		let disposed = false;
		const scheduler = new root.AlicornDemandScheduler({
			visible: !root.document.hidden,
			runFrame: nowNs => {
				const state = exports.alicorn_browser_status(context);
				if (state === -2) {
					disposed = true;
					scheduler.dispose();
					return { hasMoreWork: false, nextWakeNs: 0n, notifyIdle: false };
				}
				if (state === 3) {
					const hasMoreWork = !!exports.alicorn_browser_frame(nowNs, context);
					const nextState = exports.alicorn_browser_status(context);
					if (nextState === -2) {
						disposed = true;
						scheduler.dispose();
					}
					return { hasMoreWork, nextWakeNs: 0n, notifyIdle: false };
				}
				if (state < 0) {
					if (status) status.textContent = "WebGPU initialization failed. Check the browser console.";
					return { hasMoreWork: false, nextWakeNs: 0n, notifyIdle: false };
				}
				if (state === 2) {
					if (status) status.textContent = "The WebGPU device was lost. This host does not recreate devices yet.";
					return { hasMoreWork: false, nextWakeNs: 0n, notifyIdle: false };
				}
				if (state !== 1) return { hasMoreWork: false, nextWakeNs: 0n, notifyIdle: false };
				if (status && status.textContent !== readyMessage) status.textContent = readyMessage;
				const hasMoreWork = !!exports.alicorn_browser_frame(nowNs, context);
				return {
					hasMoreWork,
					nextWakeNs: exports.alicorn_browser_next_wake_ns(context),
				};
			},
			onError: error => {
				if (status) status.textContent = "Browser runtime error: " + String(error && error.message || error);
				root.console.error("[alicorn-webgpu] scheduled frame failed", error);
			},
		});
		root.__alicornDemandScheduler = scheduler;
		if (status) status.textContent = "Starting the retained runtime and requesting a WebGPU device…";
		const dispatchCallback = wgpuInterface.callCallback.bind(wgpuInterface);
		wgpuInterface.callCallback = (callback, args) => {
			try { dispatchCallback(callback, args); }
			finally { scheduler.wake(); }
		};
		const canvas = root.document.getElementById(options.canvasId || "alicorn-canvas");
		if (!canvas) throw new Error("The page must contain the configured Alicorn canvas.");
		root.addEventListener("resize", () => {
			exports.alicorn_browser_resize(context);
			scheduler.wake();
		});
		root.document.addEventListener("visibilitychange", () => scheduler.setVisible(!root.document.hidden));
		root.addEventListener("pagehide", () => {
			if (disposed) return;
			if (exports.alicorn_browser_shutdown(context)) {
				disposed = true;
				scheduler.dispose();
			}
		});
		root.addEventListener("pageshow", () => {
			if (!disposed) scheduler.setVisible(!root.document.hidden);
		});
		root.addEventListener("error", event => {
			if (status) status.textContent = "Browser runtime error: " + String(event.message || event.error || "unknown error");
		}, { once: true });
		exports._start();
		scheduler.wake();
		return { instance, exports, scheduler };
	}

	root.AlicornWebGPUHost = { start };
})(globalThis);
