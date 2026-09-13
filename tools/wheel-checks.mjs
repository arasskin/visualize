import assert from 'node:assert/strict';
import { InputHandler } from '../src.wterm/wterm-dom-input.js';

function fixture() {
  const sent = [];
  const bridge = { mouseTracking: () => 1002, mouseSgr: () => true, getRows: () => 24, getCols: () => 80 };
  const handler = Object.create(InputHandler.prototype);
  handler.getBridge = () => bridge;
  handler.getCellSize = () => ({charWidth: 10, rowHeight: 20});
  handler.element = {
    ownerDocument: {defaultView: {}},
    querySelector: () => ({getBoundingClientRect: () => ({left: 0, top: 0})}),
    getBoundingClientRect: () => ({left: 0, top: 0, width: 800, height: 480}),
  };
  handler.onData = data => sent.push(data);
  let time = 0;
  function wheel(deltaY, options = {}) {
    let prevented = false;
    const event = {
      deltaMode: 0, deltaX: 0, deltaY, timeStamp: ++time,
      clientX: 25, clientY: 45, buttons: 0,
      preventDefault: () => { prevented = true; }, ...options,
    };
    handler.handleMouse(event, 'wheel');
    return prevented;
  }
  return {handler, bridge, sent, wheel};
}
const down = '\x1b[<65;3;3M';
const up = '\x1b[<64;3;3M';
{
  const {wheel, sent} = fixture();
  for (let i = 0; i < 19; i++) assert.equal(wheel(1), true);
  assert.deepEqual(sent, []);
  wheel(1);
  assert.deepEqual(sent, [down]);
  wheel(45);
  wheel(15);
  assert.deepEqual(sent, [down, down.repeat(2), down]);
}
{
  const {wheel, sent} = fixture();
  wheel(19);
  wheel(-1);
  assert.deepEqual(sent, []);
  wheel(-19);
  assert.deepEqual(sent, [up]);
}
{
  const {wheel, sent} = fixture();
  wheel(19);
  wheel(1, {timeStamp: 500});
  assert.deepEqual(sent, []);
}
{
  const {wheel, sent} = fixture();
  wheel(19);
  wheel(1, {shiftKey: true});
  assert.deepEqual(sent, []);
  wheel(19, {shiftKey: true});
  assert.deepEqual(sent, ['\x1b[<69;3;3M']);
}
{
  const {wheel, sent} = fixture();
  wheel(0, {deltaX: 9});
  assert.deepEqual(sent, []);
  wheel(0, {deltaX: 1});
  assert.deepEqual(sent, ['\x1b[<67;3;3M']);
  wheel(19);
  assert.equal(sent.length, 1);
}
{
  const {wheel, sent} = fixture();
  wheel(3, {deltaMode: 1});
  wheel(-1, {deltaMode: 2});
  assert.deepEqual(sent, [down.repeat(3), up.repeat(24)]);
}
{
  const {wheel, sent, bridge} = fixture();
  wheel(19);
  bridge.mouseTracking = () => 0;
  assert.equal(wheel(20), false);
  assert.deepEqual(sent, []);
  bridge.mouseTracking = () => 1002;
  wheel(1);
  assert.deepEqual(sent, []);
}
{
  const {wheel, sent} = fixture();
  assert.equal(wheel(0), false);
  assert.equal(wheel(NaN), false);
  assert.deepEqual(sent, []);
}
console.log('Wheel checks passed: pixel accumulation, fractional carry, direction, idle reset, modifiers, axes, line/page units, and native scrollback.');
