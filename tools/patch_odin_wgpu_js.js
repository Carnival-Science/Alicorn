"use strict";

const fs = require("node:fs");

function skipWhitespace(source, index) {
	while (index < source.length && /\s/.test(source[index])) index++;
	return index;
}

function matchingBrace(source, open) {
	if (source[open] !== "{") throw new Error("Expected an opening brace.");
	let depth = 0;
	let quote = null;
	let lineComment = false;
	let blockComment = false;
	for (let i = open; i < source.length; i++) {
		const ch = source[i];
		const next = source[i + 1];
		if (lineComment) {
			if (ch === "\n") lineComment = false;
			continue;
		}
		if (blockComment) {
			if (ch === "*" && next === "/") {
				blockComment = false;
				i++;
			}
			continue;
		}
		if (quote !== null) {
			if (ch === "\\") {
				i++;
				continue;
			}
			if (ch === quote) quote = null;
			continue;
		}
		if (ch === "/" && next === "/") {
			lineComment = true;
			i++;
			continue;
		}
		if (ch === "/" && next === "*") {
			blockComment = true;
			i++;
			continue;
		}
		if (ch === "\"" || ch === "'" || ch === "`") {
			quote = ch;
			continue;
		}
		if (ch === "{") depth++;
		if (ch === "}" && --depth === 0) return i;
	}
	throw new Error("Unclosed JavaScript callback body.");
}

// Odin's pinned WGPU JS bridge chains catch(...).then(...). Since catch turns
// a rejection into a fulfilled promise, that shape calls both the error and
// success callbacks. Move the error handler to then's rejection argument so
// every one-shot C callback is dispatched exactly once.
function patchSource(source, expectedCount = 8) {
	let output = source;
	let cursor = 0;
	let replacements = 0;
	const catchPrefix = ".catch((e) => {";
	while (true) {
		const catchStart = output.indexOf(catchPrefix, cursor);
		if (catchStart < 0) break;
		const errorOpen = catchStart + catchPrefix.length - 1;
		const errorClose = matchingBrace(output, errorOpen);
		const catchClose = skipWhitespace(output, errorClose + 1);
		if (output[catchClose] !== ")") {
			throw new Error("Unexpected syntax after WGPU promise rejection callback.");
		}
		const thenStart = skipWhitespace(output, catchClose + 1);
		if (!output.startsWith(".then(", thenStart)) {
			throw new Error("Expected the WGPU rejection callback to be followed by .then().");
		}
		const thenArgsStart = thenStart + ".then(".length;
		const successArrow = output.indexOf("=>", thenArgsStart);
		if (successArrow < 0) throw new Error("Expected a WGPU promise success callback.");
		const successOpen = output.indexOf("{", successArrow + 2);
		if (successOpen < 0) throw new Error("Expected a WGPU promise success callback body.");
		const successClose = matchingBrace(output, successOpen);
		const thenClose = skipWhitespace(output, successClose + 1);
		if (output[thenClose] !== ")") throw new Error("Unexpected syntax after WGPU promise success callback.");

		const successCallback = output.slice(thenArgsStart, successClose + 1);
		const errorBody = output.slice(errorOpen + 1, errorClose);
		const replacement = `.then(${successCallback}, (e) => {${errorBody}})`;
		output = output.slice(0, catchStart) + replacement + output.slice(thenClose + 1);
		cursor = catchStart + replacement.length;
		replacements++;
	}
	if (replacements !== expectedCount) {
		throw new Error(`Expected ${expectedCount} one-shot WGPU promise callbacks, patched ${replacements}; review the Odin SDK bridge before updating this patch.`);
	}
	return { source: output, replacements };
}

if (require.main === module) {
	const path = process.argv[2];
	if (!path || process.argv.length !== 3) {
		console.error("Usage: node tools/patch_odin_wgpu_js.js <copied-wgpu.js>");
		process.exit(2);
	}
	const original = fs.readFileSync(path, "utf8");
	const result = patchSource(original);
	fs.writeFileSync(path, result.source);
	console.log(`Patched ${result.replacements} one-shot promise callback chains in ${path}.`);
}

module.exports = { patchSource };
