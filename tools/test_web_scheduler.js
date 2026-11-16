"use strict";

const assert = require("node:assert/strict");
const DemandScheduler = require("../host/web/demand_scheduler.js");

function fakeHost() {
	let nowNs = 0n;
	let nextID = 1;
	const frames = new Map();
	const timers = new Map();
	return {
		frames,
		timers,
		now: () => nowNs,
		advance: ns => { nowNs += BigInt(ns); },
		requestAnimationFrame: callback => {
			const id = nextID++;
			frames.set(id, callback);
			return id;
		},
		cancelAnimationFrame: id => frames.delete(id),
		setTimeout: (callback, delay) => {
			const id = nextID++;
			timers.set(id, { callback, delay });
			return id;
		},
		clearTimeout: id => timers.delete(id),
		runFrame: timestamp => {
			const [id, callback] = frames.entries().next().value || [];
			assert.notEqual(id, undefined, "expected a queued animation frame");
			frames.delete(id);
			callback(Number(timestamp ?? nowNs) / 1e6);
		},
		runTimer: () => {
			const [timerID, timer] = timers.entries().next().value || [];
			assert.notEqual(timerID, undefined, "expected a queued timer");
			timers.delete(timerID);
			timer.callback();
			return timer;
		},
	};
}

function schedulerFor(host, runFrame, onIdle = null) {
	return new DemandScheduler({
		requestAnimationFrame: host.requestAnimationFrame,
		cancelAnimationFrame: host.cancelAnimationFrame,
		setTimeout: host.setTimeout,
		clearTimeout: host.clearTimeout,
		nowNs: host.now,
		runFrame,
		onIdle,
		onError: error => { throw error; },
	});
}

function testWakeCoalescesAndIdleQuiesces() {
	const host = fakeHost();
	let steps = 0;
	let idle = 0;
	const scheduler = schedulerFor(host, () => {
		steps++;
		return { hasMoreWork: false, nextWakeNs: 0n };
	}, () => idle++);
	assert.equal(scheduler.wake(), true);
	assert.equal(scheduler.wake(), false);
	assert.equal(host.frames.size, 1);
	host.runFrame();
	assert.equal(steps, 1);
	assert.equal(idle, 1);
	assert.equal(host.frames.size, 0);
	assert.equal(host.timers.size, 0);
	scheduler.dispose();
}

function testWorkRequestsOnlyTheNextFrame() {
	const host = fakeHost();
	let steps = 0;
	const scheduler = schedulerFor(host, () => ({ hasMoreWork: ++steps < 3, nextWakeNs: 0n }));
	scheduler.wake();
	for (let expected = 1; expected <= 3; expected++) {
		host.runFrame();
		assert.equal(steps, expected);
		assert.equal(host.frames.size, expected < 3 ? 1 : 0);
	}
	scheduler.dispose();
}

function testDeadlineUsesBoundedTimerAndRechecksEarlyWake() {
	const host = fakeHost();
	let steps = 0;
	const scheduler = schedulerFor(host, () => {
		steps++;
		return { hasMoreWork: false, nextWakeNs: steps === 1 ? 10_000_000n : 0n };
	});
	scheduler.wake();
	host.runFrame();
	assert.equal(host.frames.size, 0);
	assert.equal(host.timers.size, 1);
	assert.equal(host.timers.values().next().value.delay, 10);
	host.advance(5_000_000n);
	host.runTimer();
	assert.equal(host.frames.size, 0, "early timeout must not run the app");
	assert.equal(host.timers.size, 1, "early timeout must re-arm the remaining deadline");
	host.advance(5_000_000n);
	host.runTimer();
	assert.equal(host.frames.size, 1);
	host.runFrame();
	assert.equal(steps, 2);
	assert.equal(host.timers.size, 0);
	scheduler.dispose();
}

function testVisibilitySuspendsAndResumesFromNow() {
	const host = fakeHost();
	const scheduler = schedulerFor(host, () => ({ hasMoreWork: false, nextWakeNs: 30_000_000n }));
	scheduler.wake();
	scheduler.setVisible(false);
	assert.equal(host.frames.size, 0, "hidden page cancels queued frame");
	assert.equal(host.timers.size, 0, "hidden page cancels deadline timer");
	scheduler.wake();
	assert.equal(host.frames.size, 0, "hidden page ignores input wakes");
	scheduler.setVisible(true);
	assert.equal(host.frames.size, 1, "visible page immediately catches up once");
	host.runFrame();
	assert.equal(host.timers.size, 1);
	scheduler.dispose();
}

function testWakeDuringStepIsNotLost() {
	const host = fakeHost();
	let scheduler;
	let steps = 0;
	scheduler = schedulerFor(host, () => {
		steps++;
		if (steps === 1) scheduler.wake();
		return { hasMoreWork: false, nextWakeNs: 0n };
	});
	scheduler.wake();
	host.runFrame();
	assert.equal(steps, 1);
	assert.equal(host.frames.size, 1, "reentrant completion wake schedules another frame");
	host.runFrame();
	assert.equal(steps, 2);
	assert.equal(host.frames.size, 0);
	scheduler.dispose();
}

function testLongDeadlineUsesClampedTimeoutAndRearms() {
	const host = fakeHost();
	const deadline = host.now() + 3_000_000_000_000_000n;
	const scheduler = schedulerFor(host, () => ({ hasMoreWork: false, nextWakeNs: deadline }));
	scheduler.wake();
	host.runFrame();
	assert.equal(host.timers.values().next().value.delay, 2_147_483_647);
	host.advance(2_147_483_647_000_000n);
	host.runTimer();
	assert.equal(host.frames.size, 0, "clamped timeout must re-arm until the absolute deadline");
	assert.equal(host.timers.values().next().value.delay, 852_516_353);
	scheduler.dispose();
}

function testInitiallyHiddenHostDoesNotScheduleUntilVisible() {
	const host = fakeHost();
	const scheduler = new DemandScheduler({
		visible: false,
		requestAnimationFrame: host.requestAnimationFrame,
		cancelAnimationFrame: host.cancelAnimationFrame,
		setTimeout: host.setTimeout,
		clearTimeout: host.clearTimeout,
		nowNs: host.now,
		runFrame: () => ({ hasMoreWork: false, nextWakeNs: 0n }),
	});
	assert.equal(scheduler.wake(), false);
	assert.equal(host.frames.size, 0);
	scheduler.setVisible(true);
	assert.equal(host.frames.size, 1);
	scheduler.dispose();
}

for (const test of [
	testWakeCoalescesAndIdleQuiesces,
	testWorkRequestsOnlyTheNextFrame,
	testDeadlineUsesBoundedTimerAndRechecksEarlyWake,
	testVisibilitySuspendsAndResumesFromNow,
	testWakeDuringStepIsNotLost,
	testLongDeadlineUsesClampedTimeoutAndRearms,
	testInitiallyHiddenHostDoesNotScheduleUntilVisible,
]) {
	test();
	console.log(`PASS ${test.name}`);
}
