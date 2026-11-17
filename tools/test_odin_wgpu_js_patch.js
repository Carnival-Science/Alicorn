"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");
const { patchSource } = require("./patch_odin_wgpu_js.js");

async function testPromiseCallbacksAreSingleShotOnSuccessAndFailure() {
	const source = `function run(shouldReject) {
	const calls = [];
	const promise = shouldReject ? Promise.reject(new Error("failure")) : Promise.resolve("ok");
	return promise
		.catch((e) => {
			if (e.message === "failure") { calls.push("error"); }
		})
		.then((value) => {
			if (value === "ok") { calls.push("success"); }
		})
		.then(() => calls);
}`;
	const result = patchSource(source, 1);
	const outcomes = await vm.runInNewContext(
		result.source + "\nPromise.all([run(false), run(true)])",
		{ Promise, Error },
	);
	assert.deepEqual(Array.from(outcomes[0]), ["success"]);
	assert.deepEqual(Array.from(outcomes[1]), ["error"]);
	assert.equal(result.replacements, 1);
}

async function testPatchRejectsAnUnexpectedSdkShape() {
	assert.throws(
		() => patchSource("const unchanged = true;", 7),
		/Expected 7 one-shot WGPU promise callbacks, patched 0/,
	);
}

(async () => {
	for (const test of [
		testPromiseCallbacksAreSingleShotOnSuccessAndFailure,
		testPatchRejectsAnUnexpectedSdkShape,
	]) {
		await test();
		console.log(`PASS ${test.name}`);
	}
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
