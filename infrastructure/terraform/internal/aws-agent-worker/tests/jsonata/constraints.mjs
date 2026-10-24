// Evaluate the exact Terraform-generated ASL expressions in the AWS-documented
// JSONata 2.0.6 function subset using a patched compatible interpreter.
// These are synthetic controls; AWS service validation/runtime remain separate.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {createHash} from 'node:crypto';
import jsonata from 'jsonata';
const records = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
const found = [];
function visit(v) {
  if (v && typeof v === 'object') {
    if (v.type === 'aws_sfn_state_machine' && v.values?.definition) found.push(v);
    for (const child of Object.values(v)) visit(child);
  }
}
records.forEach(visit);
const worker = found.map(r => JSON.parse(r.values.definition)).find(v => v.StartAt === 'ValidateInstalledInput');
const reaper = found.map(r => JSON.parse(r.values.definition)).find(v => v.States?.StopTasks?.ItemProcessor?.StartAt === 'InspectTask');
assert.ok(worker && reaper, 'actual verbose Terraform mock state must include both installed definitions');
for (const [name, value] of [['worker',worker],['reaper',reaper]]) writeFileSync(join(dirname(process.argv[2]),'synthetic-'+name+'-definition.json'),JSON.stringify(value));
const states = worker.States;
const input = {schemaVersion:1,candidateKey:'sha256:'+'a'.repeat(64),runtimeId:'runtime_01',slotId:'fixed-slot',
  executionId:'execution-'+'1'.repeat(32),targetId:'target-é',workspaceId:'workspace',turnId:'turn😀"\\',claimGeneration:7,
  expiresEpoch:1792080300,nativeBindingDigest:'sha256:'+'b'.repeat(64)};
let instant = '2026-10-15T16:00:10Z';
async function evaluate(source, value, when=instant) {
  assert.ok(source.startsWith('{%') && source.endsWith('%}'));
  const allowed = new Set(['count','keys','type','match','floor','toMillis','length','merge','substring','string','join','map','sort','lookup','j','number']);
  for (const match of source.matchAll(/\$([A-Za-z0-9]+)\s*\(/g)) assert.ok(allowed.has(match[1]),'only reviewed AWS 2.0.6 functions may be used');
  return jsonata(source.slice(2,-2)).evaluate(null, {states:{input:value,context:{
    State:{EnteredTime:when},Execution:{StartTime:'2026-10-15T16:00:00Z'}}}});
}
async function accepted(value) {
  try { return await evaluate(states.ValidateInstalledInput.Choices[0].Condition,value) === true; }
  catch { return false; }
}
assert.equal(await accepted(input),true);
for (const value of [
  {...input,extra:true}, {...input,schemaVersion:2}, {...input,candidateKey:'sha256:'+'c'.repeat(64)},
  {...input,runtimeId:'foreign'}, {...input,slotId:'other-slot'}, {...input,executionId:'execution-'+'A'.repeat(32)},
  {...input,expiresEpoch:1792080009}, {...input,expiresEpoch:1792086001}, {...input,expiresEpoch:1792166401},
  {...input,claimGeneration:0}, {...input,claimGeneration:1.5}, {...input,claimGeneration:9007199254740992}
]) assert.equal(await accepted(value),false, 'closed identity, integer clocks and original funding bounds must refuse');
const canonical = await evaluate(states.CanonicalInstalledInput.Output,input);
const expected = '{"candidateKey":"sha256:'+'a'.repeat(64)+'","claimGeneration":7,"executionId":"execution-'+'1'.repeat(32)+'","expiresEpoch":1792080300,"nativeBindingDigest":"sha256:'+'b'.repeat(64)+'","runtimeId":"runtime_01","schemaVersion":1,"slotId":"fixed-slot","targetId":"target-é","turnId":"turn😀\\\"\\\\","workspaceId":"workspace"}';
assert.equal(canonical._slot.inputString,expected,'canonical input must preserve UTF-8/escape bytes and sorted keys');
assert.deepEqual(JSON.parse(expected),input);
assert.equal(canonical._slot.nameInput,'{"candidateKey":"'+input.candidateKey+'","executionId":"'+input.executionId+'"}');
const executionName='worker-'+createHash('sha256').update(canonical._slot.nameInput,'utf8').digest('hex');
assert.match(executionName,/^worker-[0-9a-f]{64}$/);
const cleanup = reaper.States.StopTasks.ItemProcessor.States;
const arn = 'arn:aws:ecs:us-east-1:123456789012:task/isolated-agents/original';
const tags = {'honua-agent-candidate':input.candidateKey,'honua-agent-attempt':input.slotId,
  'honua-agent-runtime':input.runtimeId,'honua-agent-slot':input.slotId,'honua-agent-execution':input.executionId,
  'honua-agent-execution-expires':String(input.expiresEpoch)};
const task = {TaskArn:arn,ClusterArn:states.RunWorker.Parameters.Cluster,
  TaskDefinitionArn:states.RunWorker.Parameters.TaskDefinition,CreatedAt:1792080005,LastStatus:'RUNNING',
  Tags:Object.entries(tags).map(([Key,Value])=>({Key,Value}))};
const observed={taskArn:arn,observed:{Failures:[],Tasks:[task]}};
assert.equal(await evaluate(cleanup.CheckIdentity.Choices[0].Condition,observed),true);
assert.equal(await evaluate(cleanup.CheckIdentity.Choices[0].Condition,{...observed,observed:{Failures:[],Tasks:[]}}),false);
assert.equal(await evaluate(cleanup.CheckIdentity.Choices[0].Condition,{...observed,observed:{Failures:[],Tasks:[{...task,TaskDefinitionArn:'foreign'}]}}),false);
for(const created of [1792080005,'2026-10-15T16:00:05Z']) {
 const value={...observed,observed:{Failures:[],Tasks:[{...task,CreatedAt:created}]}};
 assert.equal(await evaluate(cleanup.CheckExecutionExpiry.Choices[1].Condition,value),false);
 assert.equal(await evaluate(cleanup.CheckExecutionExpiry.Choices[1].Condition,value,'2026-10-15T16:05:00Z'),true);
}
console.log(JSON.stringify({engine:'jsonata@2.2.2',language:'AWS JSONata 2.0.6 subset',source:'actual Terraform mock-state ASL',controls:'closed-input/canonical-UTF8/expiry/foreign-and-missing-ECS',passed:true,qualification:false}));
