"""Isolated recipe-engine integration checks; never use a live Incus daemon."""
import json
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'
HARNESS = r'''
import std/[os, json]
import recipe_engine, recipe_exec
proc clone(name, snapshot: string): int =
  writeFile(getEnv("FAKE_STATE"), $(%*[{"name": "ocdev-" & name,
    "status": "Running", "config": {"volatile.uuid": "fixture-uuid"}}]))
  0
proc remove(name: string): int =
  writeFile(getEnv("FAKE_STATE"), "[]")
  0
try:
  let a = commandLineParams()
  var r: JsonNode
  case a[0]
  of "timeout":
    let e = execute(@["incus", "exec", "SLEEP"], timeoutMs = 50)
    r = %*{"exitCode": e.code}
  of "create": r = createEnvironment("demo", a[1], "", a[2] == "true", clone)
  of "project": r = createEnvironment("demo", "", a[1], a[2] == "true", clone)
  of "setup": r = setupEnvironment("demo", a[1] == "true", a[2] == "true")
  of "inspect": r = inspectEnvironment("demo")
  of "tasks": r = taskList("demo")
  of "task": r = taskRun("demo", a[1], parseJson(a[2]))
  of "runs": r = runsList("demo")
  of "show": r = runShow(a[1])
  of "services": r = services("demo", a[1], a[2], 5)
  of "delete": r = deleteEnvironment("demo", a[1] == "true", remove)
  else: quit(3)
  echo $r
except EngineError as e:
  stderr.writeLine($( %*{"code": e.code, "operationId": e.operationId, "error": e.msg}))
  quit(1)
except CatchableError as e:
  stderr.writeLine(e.msg)
  quit(1)
'''
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
data = sys.stdin.read() if a[0] == 'exec' else ''
with open(os.environ['FAKE_TRACE'], 'a') as f:
    f.write(json.dumps({'args': a, 'input': data}) + '\n')
if a[0] == 'list':
    if os.environ.get('BAD_LIST'): print('invalid')
    else:
        items = json.loads(Path(os.environ['FAKE_STATE']).read_text())
        if len(a) > 2:
            target = a[2].removeprefix('^').removesuffix('$')
            items = [x for x in items if x['name'] == target]
        print(json.dumps(items))
elif a[0] == 'query':
    if os.environ.get('MISSING_SNAPSHOT'): sys.exit(1)
    if '/snapshots/' in a[1]: print(json.dumps({'name': 'ready', 'config': {'volatile.uuid': 'base-uuid'}}))
    elif '/storage-pools/' in a[1]: print(json.dumps({'driver': os.environ.get('DRIVER', 'btrfs')}))
    else: print(json.dumps({'expanded_devices': {'root': {'pool': 'fixture'}}}))
elif a[0] == 'exec':
    if 'SLEEP' in a:
        import time
        time.sleep(10)
    if 'FAIL' in a: print('SECRET_SENTINEL'); sys.exit(7)
    if 'ocdev-seed' in a and os.environ.get('EXEC_SEEDS'):
        import subprocess
        guest = Path(os.environ['HOME']) / 'guest'
        guest.mkdir(exist_ok=True)
        script = a[a.index('-c') + 1]
        mode = a[a.index('ocdev-seed') + 2]
        p = subprocess.run(['/bin/sh', '-c', script, 'ocdev-seed', str(guest), mode, str(guest/'config')], input=data, text=True)
        sys.exit(p.returncode)
    if 'process-compose' in a:
        if 'list' in a: print('bad' if os.environ.get('BAD_SERVICES') else '[{"name":"api","status":"Running","command":"PRIVATE"}]')
        elif 'logs' in a: print('line\npassword=SECRET_SENTINEL\n' + 'x' * 70000)
    else: print('SECRET_SENTINEL')
else: sys.exit(9)
'''


class RecipeEngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='ocdev-engine-build-')
        build = Path(cls.build.name)
        (build / 'harness.nim').write_text(HARNESS)
        cls.binary = build / 'engine-test'
        nim = shutil.which('nim')
        if nim is None:
            raise RuntimeError('Nim must be installed and available on PATH to run engine tests')
        subprocess.run([nim, 'c', '--hints:off', f'--path:{SRC}',
                        f'--nimcache:{build / "cache"}', f'-o:{cls.binary}',
                        str(build / 'harness.nim')], check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ocdev-engine-test-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        (self.home / 'incus').write_text(FAKE)
        (self.home / 'incus').chmod(0o755)
        (self.home / 'state').write_text('[]')
        self.env = {**os.environ, 'HOME': str(self.home),
                    'PATH': f'{self.home}:{os.environ["PATH"]}',
                    'FAKE_STATE': str(self.home / 'state'), 'FAKE_TRACE': str(self.home / 'trace')}
        self.recipe = {'schemaVersion': 1, 'id': 'generic', 'name': 'Generic',
                       'source': {'snapshot': 'base/ready'},
                       'tasks': {'prepare': self.task('prepare'), 'check': self.task('check')},
                       'hooks': {'afterCreate': ['prepare', 'check'], 'beforeDelete': ['check']}}
        self.path = self.home / 'recipe.json'
        self.persist()

    def task(self, command):
        return {'kind': 'command', 'cwd': '/home/dev', 'command': command, 'args': []}

    def persist(self):
        self.path.write_text(json.dumps(self.recipe))

    def call(self, *args, ok=True):
        p = subprocess.run([str(self.binary), *map(str, args)], env=self.env,
                           text=True, capture_output=True, timeout=20)
        self.assertEqual(p.returncode, 0 if ok else 1, p.stderr)
        if ok:
            self.assertEqual(p.stderr, '')
            return json.loads(p.stdout)
        self.assertEqual(p.stdout, '')
        self.assertNotIn('SECRET_SENTINEL', p.stderr)
        return p.stderr

    def create(self):
        return self.call('create', self.path, 'false')

    def trace(self):
        return [json.loads(x) for x in (self.home / 'trace').read_text().splitlines()]

    def test_dry_run_queries_without_writes_and_storage_rejection(self):
        result = self.call('create', self.path, 'true')
        self.assertTrue(result['dryRun'])
        self.assertFalse((self.home / '.ocdev').exists())
        self.assertTrue(any('/1.0/instances/ocdev-base/snapshots/ready' in x['args'] for x in self.trace()))
        self.env['DRIVER'] = 'dir'
        self.call('create', self.path, 'true', ok=False)
        self.assertFalse((self.home / '.ocdev').exists())

    def test_order_pinning_private_state_and_explicit_rerun(self):
        result = self.create()
        self.assertEqual(result['setupStatus'], 'complete')
        self.assertEqual(result['servicesReady'], 'unknown')
        commands = [x['args'][-1] for x in self.trace() if x['args'][0] == 'exec']
        self.assertEqual(commands, ['prepare', 'check'])
        self.recipe['tasks']['check']['command'] = 'FAIL'
        self.persist()
        self.call('task', 'check', '{}')
        self.call('setup', 'false', 'false', ok=False)
        self.call('setup', 'false', 'true')
        for p in (self.home / '.ocdev').rglob('*.json'):
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('SECRET_SENTINEL', json.dumps(self.call('runs')))

    def test_typed_inputs_stdin_and_secret_non_disclosure(self):
        self.recipe['tasks']['check']['inputs'] = {
            'key': {'type': 'string', 'secret': True},
            'options': {'type': 'stringList', 'choices': ['one', 'two']}}
        self.persist()
        self.create()
        value = 'SECRET_SENTINEL; $(touch /tmp/not-executed)'
        self.call('task', 'check', json.dumps({'key': value, 'options': ['one']}))
        execution = [x for x in self.trace() if x['args'][0] == 'exec'][-1]
        self.assertEqual(json.loads(execution['input'])['key'], value)
        self.assertNotIn(value, json.dumps(execution['args']))
        self.call('task', 'check', '{"key":17}', ok=False)
        self.call('task', 'check', '{"options":["invalid"]}', ok=False)
        self.assertNotIn('SECRET_SENTINEL', json.dumps(self.call('runs')))

    def test_failed_hook_is_recorded_and_retained(self):
        self.recipe['tasks']['check']['command'] = 'FAIL'
        self.persist()
        error = json.loads(self.call('create', self.path, 'false', ok=False))
        run = self.call('show', error['operationId'])
        self.assertEqual(run['status'], 'failed')
        self.assertEqual(run['steps'][-1]['exitCode'], 7)
        self.assertEqual(self.call('inspect')['setupStatus'], 'failed')
        self.call('delete', 'false', ok=False)
        self.assertTrue(json.loads((self.home / 'state').read_text()))

    def test_seed_preflight_delivery_and_reread(self):
        project = self.home / 'project.json'
        project.write_text(json.dumps({'schemaVersion': 1, 'id': 'fixture', 'recipePath': str(self.path),
            'seedFiles': [{'id': 'config', 'source': 'seed', 'destination': '/home/dev/config',
                           'mode': '0600', 'required': True}]}))
        self.call('project', project, 'false', ok=False)
        self.assertEqual((self.home / 'state').read_text(), '[]')
        (self.home / 'seed').write_text('dummy-first')
        self.call('project', project, 'false')
        (self.home / 'seed').write_text('dummy-second')
        self.call('setup', 'false', 'true')
        deliveries = [x for x in self.trace() if 'ocdev-seed' in x['args']]
        self.assertEqual([x['input'] for x in deliveries], ['dummy-first', 'dummy-second'])
        pinned = (self.home / '.ocdev/environments/demo.json').read_text()
        self.assertNotIn('dummy-first', pinned)
        self.assertNotIn('dummy-second', pinned)

    def test_uuid_mismatch_and_malformed_backend_fail_closed(self):
        self.create()
        state = json.loads((self.home / 'state').read_text())
        state[0]['config']['volatile.uuid'] = 'replacement'
        (self.home / 'state').write_text(json.dumps(state))
        self.assertFalse(self.call('inspect')['identityMatches'])
        self.call('task', 'check', '{}', ok=False)
        self.call('delete', 'false', ok=False)
        self.env['BAD_LIST'] = '1'
        self.call('inspect', ok=False)

    def test_services_projection_logs_and_delete_preview(self):
        self.recipe['processCompose'] = {'cwd': '/home/dev', 'file': 'process-compose.yaml',
                                         'services': ['api'], 'autostart': True}
        self.persist()
        self.create()
        items = self.call('services', 'list', '')
        self.assertEqual(items, [{'name': 'api', 'status': 'Running', 'ready': 'unknown'}])
        logs = self.call('services', 'logs', 'api')
        self.assertTrue(logs['truncated'])
        self.assertNotIn('SECRET_SENTINEL', logs['logs'])
        self.env['BAD_SERVICES'] = '1'
        self.call('services', 'list', '', ok=False)
        preview = self.call('delete', 'true')
        self.assertEqual(preview['ownedResources'], ['ocdev-demo'])
        self.call('delete', 'false')
        self.assertEqual(json.loads((self.home / 'state').read_text()), [])
        self.assertFalse((self.home / '.ocdev/environments/demo.json').exists())

    def test_bounded_host_timeout_and_cross_process_lock(self):
        self.assertEqual(self.call('timeout')['exitCode'], 124)
        self.create()
        lock = self.home / '.ocdev/environments/demo.lock'
        with lock.open() as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            error = self.call('task', 'check', '{}', ok=False)
            self.assertIn('already running', error)
        self.call('task', 'check', '{}')

    def test_missing_instance_reconciles_metadata_without_hooks(self):
        self.create()
        (self.home / 'state').write_text('[]')
        before = len(self.trace())
        preview = self.call('delete', 'true')
        self.assertTrue(preview['metadataOnly'])
        result = self.call('delete', 'false')
        self.assertTrue(result['metadataOnly'])
        self.assertFalse((self.home / '.ocdev/environments/demo.json').exists())
        self.assertFalse(any(x['args'][0] == 'exec' for x in self.trace()[before:]))
        self.create()

    def test_unrelated_large_fleet_does_not_break_target(self):
        items = [{'name': f'unrelated-{i}', 'status': 'Running', 'config': {'extra': 'x'*4096}} for i in range(20)]
        (self.home / 'state').write_text(json.dumps(items))
        self.call('create', self.path, 'true')
        self.assertFalse((self.home / '.ocdev').exists())

    def test_unsatisfiable_hooks_rejected_before_clone(self):
        self.recipe['tasks']['check']['inputs'] = {'key': {'type':'string','required':True,'secret':True}}
        self.persist()
        self.call('create',self.path,'true',ok=False)
        self.assertFalse((self.home / '.ocdev').exists())
        self.call('create',self.path,'false',ok=False)
        self.assertEqual(json.loads((self.home / 'state').read_text()),[])

    def test_readonly_seeds_are_atomic_and_rerunnable(self):
        self.env['EXEC_SEEDS']='1'
        (self.home/'seed').write_text('first')
        project = self.home/'project.json'
        project.write_text(json.dumps({'schemaVersion':1,'id':'fixture','recipePath':str(self.path),
            'seedFiles':[{'id':'config','source':'seed','destination':'/home/dev/config','mode':'0400','required':True}]}))
        self.call('project',project,'false')
        destination = self.home/'guest/config'
        self.assertEqual(destination.read_text(),'first')
        self.assertEqual(destination.stat().st_mode & 0o777,0o400)
        (self.home/'seed').write_text('second')
        self.call('setup','false','true')
        self.assertEqual(destination.read_text(),'second')
        failing_cat = self.home/'cat'
        failing_cat.write_text('#!/bin/sh\nexit 1\n')
        failing_cat.chmod(0o755)
        self.call('setup','false','true',ok=False)
        self.assertEqual(destination.read_text(),'second')
        self.assertEqual(list((self.home/'guest').glob('.ocdev-seed-*')),[])

    def test_seed_directory_rejected_and_symlink_replaced(self):
        self.env['EXEC_SEEDS']='1'
        (self.home/'seed').write_text('replacement')
        project = self.home/'project.json'
        project.write_text(json.dumps({'schemaVersion':1,'id':'fixture','recipePath':str(self.path),
            'seedFiles':[{'id':'config','source':'seed','destination':'/home/dev/config','mode':'0600','required':True}]}))
        destination = self.home/'guest/config'
        destination.mkdir(parents=True)
        self.call('project',project,'false',ok=False)
        self.assertTrue(destination.is_dir())
        self.assertEqual(list(destination.iterdir()),[])
        self.assertEqual(list(destination.parent.glob('.ocdev-seed-*')),[])
        destination.rmdir()
        target = self.home/'other-directory'
        target.mkdir()
        destination.symlink_to(target,target_is_directory=True)
        self.call('setup','false','true')
        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.read_text(),'replacement')
        self.assertEqual(list(target.iterdir()),[])

    def test_stale_operation_is_inspectable_as_interrupted(self):
        result = self.create()
        path = self.home / '.ocdev/runs' / (result['operationId'] + '.json')
        op = json.loads(path.read_text())
        op['status'] = 'running'
        op['steps'][-1]['status'] = 'running'
        path.write_text(json.dumps(op))
        shown = self.call('show', result['operationId'])
        self.assertEqual(shown['status'], 'interrupted')
        self.assertEqual(shown['steps'][-1]['status'], 'interrupted')


if __name__ == '__main__':
    unittest.main()
