import test from 'node:test';
import assert from 'node:assert/strict';
import {assertStableVersionAdvance} from '../release-train-lib.mjs';
test('Stable promotion cannot roll the default channel backwards',()=>{
 assert.throws(()=>assertStableVersionAdvance('1.8.9',['1.9.0']),/advance/);
 assert.throws(()=>assertStableVersionAdvance('1.9.0',['1.9.0']),/advance/);
 assert.doesNotThrow(()=>assertStableVersionAdvance('1.10.0',['1.9.0']));
 assert.doesNotThrow(()=>assertStableVersionAdvance('1.9.0',['1.9.0'],true));
 assert.throws(()=>assertStableVersionAdvance('1.9.0',['1.10.0'],true),/advance/);
});
