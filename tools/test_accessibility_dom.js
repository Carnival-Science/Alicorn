"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

class FakeElement {
	constructor(localName, document) {
		this.localName = localName;
		this.ownerDocument = document;
		this.attributes = new Map();
		this.children = [];
		this.parentNode = null;
		this.style = {};
		this.textContent = "";
		this.value = "";
		this.disabled = false;
		this.checked = false;
		this.rect = { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 };
		this.listeners = new Map();
	}
	get nextElementSibling() {
		if (!this.parentNode) return null;
		const index = this.parentNode.children.indexOf(this);
		return this.parentNode.children[index + 1] || null;
	}
	setAttribute(name, value) { this.attributes.set(name, String(value)); }
	getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
	hasAttribute(name) { return this.attributes.has(name); }
	removeAttribute(name) { this.attributes.delete(name); }
	appendChild(child) {
		child.remove();
		child.parentNode = this;
		this.children.push(child);
		return child;
	}
	insertBefore(child, before) {
		child.remove();
		child.parentNode = this;
		const index = before ? this.children.indexOf(before) : -1;
		if (index < 0) this.children.push(child);
		else this.children.splice(index, 0, child);
		return child;
	}
	remove() {
		if (!this.parentNode) return;
		const index = this.parentNode.children.indexOf(this);
		if (index >= 0) this.parentNode.children.splice(index, 1);
		this.parentNode = null;
	}
	replaceWith(replacement) {
		if (!this.parentNode) return;
		this.parentNode.insertBefore(replacement, this.nextElementSibling);
		this.remove();
	}
	contains(element) {
		return this === element || this.children.some(child => child.contains(element));
	}
	addEventListener(name, callback) { this.listeners.set(name, callback); }
	focus() { this.ownerDocument.activeElement = this; }
	getBoundingClientRect() { return { ...this.rect }; }
}

class FakeDocument {
	constructor() {
		this.ids = new Map();
		this.body = new FakeElement("body", this);
		this.activeElement = this.body;
	}
	createElement(localName) { return new FakeElement(localName, this); }
	getElementById(id) { return this.ids.get(id) || null; }
	register(id, element) { element.id = id; this.ids.set(id, element); }
}

function makePayload(overrides = {}) {
	return {
		root: "a11y-root",
		revision: 1,
		focus: "run-button",
		showFocus: true,
		viewportWidth: 400,
		viewportHeight: 300,
		nodes: [{
			id: "run-button", parent: "", role: "button", label: "Run", description: "",
			value: "Run", checked: false, disabled: false, selected: false, expanded: false,
			canExpand: false, canCollapse: false, readOnly: false, required: false, invalid: false,
			busy: false, current: false, live: "off", liveAtomic: false, positionInSet: "",
			sizeOfSet: "", currentId: "", hasNumericValue: false, numericValue: 0,
			numericMinimum: 0, numericMaximum: 0, numericStep: 0, modified: false,
			multiline: false, canFocus: true, canPress: true, canSelect: false, canSetValue: false,
			canSetTextSelection: false, canReplaceSelectedText: false, canIncrement: false,
			canDecrement: false, canScrollIntoView: false, canScrollForward: false,
			canScrollBackward: false, canDismiss: false, order: 0, hasBounds: true,
			boundsX: 25, boundsY: 15, boundsWidth: 50, boundsHeight: 20,
		}],
		...overrides,
	};
}

function testKeyboardFocusMarkerTracksCanvasGeometryAndModality() {
	const document = new FakeDocument();
	const root = document.createElement("div");
	const canvas = document.createElement("canvas");
	document.register("a11y-root", root);
	document.register("alicorn-canvas", canvas);
	document.body.appendChild(root);
	document.body.appendChild(canvas);
	canvas.rect = { left: 10, top: 20, width: 800, height: 600, right: 810, bottom: 620 };
	const windowListeners = new Map();
	class FakeResizeObserver {
		constructor(callback) { this.callback = callback; }
		observe(element) { this.element = element; }
		disconnect() { this.disconnected = true; }
	}
	const window = {
		ResizeObserver: FakeResizeObserver,
		addEventListener(name, callback, capture) { windowListeners.set(`${name}:${!!capture}`, callback); },
		removeEventListener(name, callback, capture) {
			const key = `${name}:${!!capture}`;
			if (windowListeners.get(key) === callback) windowListeners.delete(key);
		},
	};
	vm.runInNewContext(fs.readFileSync("host/web/accessibility_dom.js", "utf8"), { window, document });
	window.alicornAccessibilityInit("a11y-root", "alicorn-canvas");
	const marker = document.body.children.find(element => element.getAttribute("aria-hidden") === "true" && element.localName === "div");
	assert.ok(marker, "the focus indicator is a separate, hidden-from-AT overlay");
	window.alicornAccessibilityApply(makePayload());
	assert.equal(marker.style.display, "block");
	assert.equal(marker.style.left, "60px");
	assert.equal(marker.style.top, "50px");
	assert.equal(marker.style.width, "100px");
	assert.equal(marker.style.height, "40px");

	window.alicornAccessibilityApply(makePayload({ showFocus: false }));
	assert.equal(marker.style.display, "none", "pointer modality suppresses the keyboard focus marker at the same semantic revision");
	window.alicornAccessibilityApply(makePayload());
	assert.equal(marker.style.display, "block", "keyboard modality restores the marker without a semantic revision");

	canvas.rect = { left: 30, top: 40, width: 400, height: 300, right: 430, bottom: 340 };
	windowListeners.get("resize:false")();
	assert.equal(marker.style.left, "55px");
	assert.equal(marker.style.top, "55px");
	assert.equal(marker.style.width, "50px");
	assert.equal(marker.style.height, "20px");

	window.alicornAccessibilityApply(makePayload({ viewportWidth: 200, viewportHeight: 150 }));
	assert.equal(marker.style.left, "80px");
	assert.equal(marker.style.top, "70px");
	assert.equal(marker.style.width, "100px");
	assert.equal(marker.style.height, "40px");

	window.alicornAccessibilityApply(makePayload({
		revision: 2,
		nodes: [{ ...makePayload().nodes[0], hasBounds: false }],
	}));
	assert.equal(marker.style.display, "none", "focus without usable semantic geometry is not drawn at an incorrect location");
	window.alicornAccessibilityDestroy("a11y-root");
	assert.equal(document.body.children.includes(marker), false, "destroy removes the overlay");
	assert.equal(canvas.hasAttribute("aria-hidden"), false, "destroy restores canvas accessibility");
	assert.equal(windowListeners.size, 0, "destroy removes geometry listeners");
}

try {
	testKeyboardFocusMarkerTracksCanvasGeometryAndModality();
	console.log("PASS testKeyboardFocusMarkerTracksCanvasGeometryAndModality");
} catch (error) {
	console.error(error);
	process.exitCode = 1;
}
