const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const context = vm.createContext({});
const source = fs.readFileSync(path.join(__dirname, 'cache-bypass-marker.js'), 'utf8')
    .replace('__BYPASS_HEADERS__', JSON.stringify(['x-honua-job-id', 'x-forwarded-client-cert', 'x-honua-canary']))
    .replace('__MARKER_COOKIE__', 'honua_cache_bypass');
vm.runInContext(source, context);
const send = (headers, cookies, requestId) => context.handler({context: {requestId}, request: {headers, cookies}});
for (const header of ['x-honua-job-id', 'x-forwarded-client-cert', 'x-honua-canary']) {
    const first = send({[header]: {value: 'a'}}, {}, 'request-1');
    const second = send({[header]: {value: 'a'}}, {}, 'request-2');
    assert.equal(first.cookies.honua_cache_bypass.value, 'request-1');
    assert.notEqual(first.cookies.honua_cache_bypass.value, second.cookies.honua_cache_bypass.value);
    assert.equal(first.headers[header].value, 'a');
}
const forged = send({}, {honua_cache_bypass: {value: 'request-1'}, honua_admin_session: {value: 's'}}, 'request-3');
assert.equal(forged.cookies.honua_cache_bypass, undefined);
assert.equal(forged.cookies.honua_admin_session.value, 's');
assert.deepEqual(send({accept: {value: 'image/png'}}, {}, 'request-4').cookies, {});
console.log('Cache bypass marker: marked requests get a key of their own, viewer-supplied markers are removed');
