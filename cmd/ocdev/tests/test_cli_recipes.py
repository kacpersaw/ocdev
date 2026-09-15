#!/usr/bin/env python3
"""Compiled CLI end-to-end tests using an isolated fake Incus, never the daemon."""
import json
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve()
FAKE = r'''import fcntl, json, os, sys, time
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
a = sys.argv[1:]
with (root / 'backend.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.loads((root / 'backend.json').read_text())
    with (root / 'calls').open('a') as log: log.write(json.dumps(a) + '\n')
    def save():
        (root / 'backend.json').write_text(json.dumps(state))
    if a[0] == 'list':
        if os.environ.get('BAD_METADATA'): print('private-sentinel'); sys.exit(1)
        print(json.dumps(list(state.values())))
    elif a[0] == 'info':
        if a[1] not in state: sys.exit(1)
        if os.environ.get('FAIL_FINAL_INFO') and a[1] != 'ocdev-base' and state[a[1]]['status'] == 'Running': sys.exit(1)
        print('Status: ' + state[a[1]]['status'].upper())
    elif a[:2] == ['snapshot', 'list']: print('ready,fixture')
    elif a[0] == 'query':
        if '/snapshots/' in a[1]: print(json.dumps({'name':'ready','config':{'volatile.uuid':'base-uuid'}}))
        elif '/storage-pools/' in a[1]: print(json.dumps({'driver': 'btrfs'}))
        else: print(json.dumps({'expanded_devices': {'root': {'pool': 'fixture'}}}))
    elif a[0] == 'copy':
        if os.environ.get('FAIL_COPY'): print('private-sentinel'); sys.exit(1)
        if a[2] in state: sys.exit(1)
        time.sleep(0.03)
        item = json.loads(json.dumps(state[a[1].split('/')[0]]))
        item.update(name=a[2], status='Stopped', config={'volatile.uuid':a[2]+'-uuid'})
        state[a[2]] = item
        save()
        print('private-sentinel')
        print('private-sentinel', file=sys.stderr)
    elif a[0] in ['start', 'stop']:
        state[a[1]]['status'] = 'Running' if a[0] == 'start' else 'Stopped'
        save()
    elif a[0] == 'delete':
        state.pop(a[1], None)
        save()
    elif a[:2] == ['config', 'device']:
        action, name = a[2:4]
        devices = state[name]['expanded_devices']
        if action == 'list': print('\n'.join(devices))
        elif action == 'get': print(devices.get(a[4], {}).get(a[5], ''))
        elif action == 'remove': devices.pop(a[4], None); save()
        elif action == 'add':
            devices[a[4]] = {'type':a[5], **dict(x.split('=',1) for x in a[6:])}
            save()
    elif a[0] == 'exec':
        data = sys.stdin.read()
        if 'FAIL' in a or (os.environ.get('FAIL_HOOK') and 'su' in a):
            print('private-sentinel'); sys.exit(7)
        if 'process-compose' in a and 'list' in a: print('[{"name":"api","status":"Running","command":"private-sentinel"}]')
        else: print('task-output')
    elif a[:2] == ['file', 'push']: pass
    elif a[0] == 'export': Path(a[2]).write_text('dummy archive')
    elif a[0] == 'import':
        name = a[2]
        state[name] = {'name':name,'status':'Stopped','config':{'volatile.uuid':name+'-uuid'},'expanded_devices':{}}
        save()
    elif a[:2] == ['config','unset']: pass
    elif a[:2] == ['profile','show']: pass
    else:
        print('Unexpected fake Incus call', file=sys.stderr); sys.exit(99)
'''

class CliRecipeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ocdev-cli-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.fake = self.root / 'bin'
        self.fake.mkdir()
        for name, script in [('incus', FAKE), ('groups', "print('incus-admin')")]:
            p = self.fake / name
            p.write_text(f'#!{sys.executable}\n' + script)
            p.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.fake), FAKE_ROOT=str(self.root))
        self.state = self.root / 'backend.json'
        self.state.write_text(json.dumps({'ocdev-base': {'name':'ocdev-base', 'status':'Running',
            'config':{'volatile.uuid':'base-uuid'}, 'expanded_devices':{
                'ssh-proxy':{'type':'proxy','listen':'tcp:0.0.0.0:2200','connect':'tcp:127.0.0.1:22'}}}}))
        self.recipe = self.root / 'recipe.json'
        self.definition = {'schemaVersion':1,'id':'demo','name':'Demo','source':{'snapshot':'base/ready'},
            'tasks':{'test':{'kind':'command','cwd':'/home/dev','command':'check','args':[]}},
            'hooks':{'afterCreate':['test'], 'beforeDelete':['test']}}
        self.persist()

    def persist(self): self.recipe.write_text(json.dumps(self.definition))
    def run_cli(self, *args, ok=True, json_mode=True):
        cmd = [str(BINARY), *map(str,args)] + (['--json'] if json_mode else [])
        r = subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode == 0, ok, r.stderr)
        if not ok:
            self.assertEqual(r.stdout, '')
            self.assertNotIn('private-sentinel', r.stderr)
            return json.loads(r.stderr) if json_mode else r.stderr
        self.assertEqual(r.stderr, '')
        return json.loads(r.stdout) if json_mode else r.stdout
    def create(self, name='demo'):
        return self.run_cli('create', name, '--recipe', self.recipe)

    def test_full_recipe_cli_json_and_legacy_routes(self):
        self.run_cli('recipe', 'validate', self.recipe)
        self.run_cli('recipe', 'add', self.recipe)
        self.assertEqual(len(self.run_cli('recipe', 'list')), 1)
        self.run_cli('recipe', 'show', 'demo')
        result = self.create()
        self.assertEqual(result['setupStatus'], 'complete')
        self.assertIn('operationId', result)
        self.assertTrue(self.run_cli('inspect', 'demo')['identityMatches'])
        self.assertEqual(len(self.run_cli('task', 'list', 'demo')), 1)
        task = self.run_cli('task', 'run', 'demo', 'test')
        self.assertIn('task-output', self.run_cli('runs', 'logs', task['operationId'])['logs'])
        self.run_cli('runs', 'show', task['operationId'])
        self.run_cli('setup', 'demo', '--rerun')
        self.run_cli('bind', 'demo', '3000:8080')
        self.assertEqual(self.run_cli('bindings')[0]['host_port'], 8080)
        self.run_cli('bind', 'demo', '--list')
        self.run_cli('unbind', 'demo', '8080')
        self.run_cli('stop', 'demo')
        self.run_cli('start', 'demo')
        self.assertIsInstance(self.run_cli('ssh', 'demo')['ssh_port'], int)
        self.run_cli('ports')
        self.run_cli('doctor')
        self.run_cli('delete', 'demo', '--dry-run')
        self.run_cli('delete', 'demo')
        self.assertNotIn('ocdev-demo', json.loads(self.state.read_text()))
        self.assertIn('ocdev-base', json.loads(self.state.read_text()))
        self.assertGreater(len(self.run_cli('runs', 'list', 'demo')), 2)

    def test_dry_run_has_no_local_side_effects(self):
        self.run_cli('create', 'demo', '--recipe', self.recipe, '--dry-run')
        self.assertFalse((self.home / '.ocdev').exists())
        calls = [json.loads(x) for x in (self.root / 'calls').read_text().splitlines()]
        self.assertTrue(all(x[0] in ['list','query'] for x in calls))

    def test_failure_has_operation_id_and_named_delete_runs_hooks(self):
        self.definition['tasks']['test']['command'] = 'FAIL'
        self.persist()
        error = self.run_cli('create', 'demo', '--recipe', self.recipe, ok=False)
        run_id = error['error']['operationId']
        self.assertEqual(self.run_cli('runs','show',run_id)['status'], 'failed')
        for spelling in [('--name','demo'), ('-n','demo'), ('--name=demo',), ('-n=demo',)]:
            self.run_cli('delete', *spelling, ok=False, json_mode=False)
            self.assertIn('ocdev-demo', json.loads(self.state.read_text()))
        for command in ['del', 'dEL', 'de-lete']:
            self.run_cli(command, 'demo', ok=False, json_mode=False)
            self.assertIn('ocdev-demo', json.loads(self.state.read_text()))

    def test_failed_clone_can_be_retried_and_reservation_released(self):
        self.env['FAIL_COPY']='1'
        self.run_cli('create','demo','--recipe',self.recipe,ok=False)
        self.assertFalse((self.home / '.ocdev/environments/demo.json').exists())
        self.assertNotIn('demo:', (self.home / '.ocdev/ports').read_text())
        self.env.pop('FAIL_COPY')
        self.create()

    def test_concurrent_plain_clones_have_unique_reserved_blocks(self):
        procs = [subprocess.Popen([str(BINARY),'create',name,'--from','base/ready','--json'],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for name in ['one','two']]
        rows=[]
        for p in procs:
            out, err = p.communicate(timeout=20)
            self.assertEqual(p.returncode,0,err)
            rows.append(json.loads(out))
        self.assertNotEqual(rows[0]['ssh_port'], rows[1]['ssh_port'])
        self.assertEqual(len((self.home / '.ocdev/ports').read_text().splitlines()),2)
        self.assertTrue(all(r['ssh_port'] != 2200 for r in rows))

    def test_legacy_hook_failure_is_nonzero_and_keeps_container(self):
        script = self.root / 'script with spaces.sh'
        script.write_text('exit 7')
        self.env['FAIL_HOOK']='1'
        self.run_cli('create','demo','--from','base/ready','--post-create',script,ok=False)
        self.assertIn('ocdev-demo',json.loads(self.state.read_text()))
        self.assertIn('demo:',(self.home / '.ocdev/ports').read_text())

    def test_unknown_options_invalid_inputs_and_shell_rejected(self):
        for args in [('recipe','list','--surprise','yes'), ('create','demo','--recipe',str(self.recipe),'--from','base/ready'),
                     ('shell','demo'), ('services','logs','demo','api','--tail','1001'),
                     ('delete','../not-a-name')]:
            with self.subTest(args=args): self.run_cli(*args,ok=False)
        self.assertFalse((self.home / '.ocdev').exists())

    def test_backend_outage_after_create_keeps_port_reservation(self):
        self.env['FAIL_FINAL_INFO']='1'
        row = self.run_cli('create','demo','--from','base/ready')
        self.assertGreater(row['ssh_port'],0)
        self.assertIn('demo:',(self.home/'.ocdev/ports').read_text())

    def test_missing_uuid_and_empty_allocations_are_valid(self):
        data = json.loads(self.state.read_text())
        data['ocdev-base']['config']={}
        self.state.write_text(json.dumps(data))
        self.assertIsNone(self.run_cli('inspect','base')['uuid'])
        self.assertIsNone(self.run_cli('ssh','base')['ssh_port'])
        self.run_cli('delete','base','--dry-run')
        (self.home/'.ocdev').mkdir()
        (self.home/'.ocdev/ports').write_text('')
        self.assertEqual(self.run_cli('ports'),[])
        self.assertTrue(self.run_cli('doctor')['ok'])

    def test_human_and_json_mutations_honor_recipe_lock(self):
        self.create()
        lock = self.home/'.ocdev/environments/demo.lock'
        with lock.open() as f:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            for json_mode in [False,True]:
                for command in ['stop', 'sto', 'sTO', 's-top']:
                    self.run_cli(command,'--name','demo',ok=False,json_mode=json_mode)
                self.run_cli('bind','demo','8080',ok=False,json_mode=json_mode)
                self.run_cli('--','sto','--name','demo',ok=False,json_mode=json_mode)
                self.run_cli('--help=false','stop','demo',ok=False,json_mode=json_mode)
        self.assertEqual(json.loads(self.state.read_text())['ocdev-demo']['status'],'Running')

    def test_empty_json_reads_do_not_initialize(self):
        self.assertEqual(self.run_cli('recipe','list'),[])
        self.assertEqual(self.run_cli('runs','list','demo'),[])
        self.assertFalse((self.home / '.ocdev').exists())

if __name__ == '__main__': unittest.main()
