const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('src/polyworld/webinputs.js', 'utf8');
for (const [query, expected] of [['?bot=base.bas:15&player=1','--player:1'], ['?bot=base.bas:15&player=16','--player:16'], ['?bot=base.bas:16', null]]) {
  const context = {window:{location:{search:query,href:'https://example.com/play/'+query}},URL,URLSearchParams,Module:{}};
  vm.runInNewContext(source,context);
  assert.equal(context.Module.arguments.find(x=>x.startsWith('--player:'))??null,expected);
  assert.ok(context.Module.arguments.includes('--bot'));
}
console.log('human seat query parameters passed');
