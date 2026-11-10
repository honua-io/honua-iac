const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, 'console-router.js'), 'utf8'), context);
const redirect = context.handler({request: {uri: '/console'}});
assert.equal(redirect.statusCode, 302);
assert.equal(redirect.headers.location.value, '/console/');
for (const uri of ['/console/', '/console/services', '/console/services/42']) {
    const querystring = {filter: {value: 'active'}};
    const result = context.handler({request: {uri, querystring}});
    assert.equal(result.uri, '/console/index.html');
    assert.equal(result.querystring, querystring);
}
for (const uri of ['/console/_framework/app.wasm', '/console/missing.js', '/healthz/ready', '/rest/services', '/console-other']) {
    assert.equal(context.handler({request: {uri}}).uri, uri);
}
console.log('Console routing: redirect, SPA navigation, assets and API isolation passed');
