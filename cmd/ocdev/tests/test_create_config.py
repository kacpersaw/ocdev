#!/usr/bin/env python3
"""Create-config CLI checks with fake Incus; pass a freshly built binary."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ocdev-config-cli-") as temp:
    root = Path(temp)
    home = root / "home"
    home.mkdir()
    bindir = root / "bin"
    bindir.mkdir()
    for name, body in {
        "groups": "print('incus-admin')\n",
        "incus": '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ['CALLS']).open('a') as f:
    f.write(json.dumps(args) + '\\n')
# Existing profile only; all source/destination info and launches fail safely.
sys.exit(0 if args == ['profile', 'show', 'ocdev'] else 1)
''',
    }.items():
        p = bindir / name
        p.write_text(f"#!{sys.executable}\n" + body)
        p.chmod(0o755)
    calls_file = root / "calls"
    env = dict(os.environ, HOME=str(home), PATH=str(bindir), CALLS=str(calls_file))
    config = home / '.ocdev' / 'config.json'

    def run(settings, *args):
        if calls_file.exists():
            calls_file.unlink()
        if settings is None:
            if config.exists():
                config.unlink()
        else:
            config.parent.mkdir(exist_ok=True)
            config.write_text(settings if isinstance(settings, str) else json.dumps(settings))
        result = subprocess.run([binary, 'create', '--name=check', *args], env=env,
                                text=True, capture_output=True, timeout=10)
        assert result.returncode != 0, result
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        return result, calls

    settings = {'base_image': 'images:ubuntu/26.04', 'default_base_source': 'my-base/stable'}
    _, calls = run(settings)
    assert calls == [['info', 'ocdev-my-base']], (calls, _)
    for flag in ('--from', '--from-snapshot'):
        _, calls = run(settings, flag, 'explicit-base/point')
        assert calls == [['info', 'ocdev-explicit-base']], calls
    for config_value, args, expected in (
        (settings, ('--fresh',), 'images:ubuntu/26.04'),
        (None, (), 'images:ubuntu/25.10'),
        ({'default_base_source': ''}, (), 'images:ubuntu/25.10'),
    ):
        _, calls = run(config_value, *args)
        launches = [c for c in calls if c[0] == 'launch']
        assert launches == [['launch', expected, 'ocdev-check', '--profile', 'default', '--profile', 'ocdev']], calls
    marker = root / 'injected'
    image = f'images:ubuntu/26.04; : > {marker}'
    _, calls = run({'base_image': image})
    assert [c for c in calls if c[0] == 'launch'][0][1] == image, calls
    assert not marker.exists()
    for invalid in ('not json', '[]', '{"base_image":42}', '{"base_image":"--help"}'):
        result, calls = run(invalid)
        assert not calls, calls
        assert 'config.json' in result.stderr, result
    _, calls = run({'default_base_source': 'bad/source/extra'})
    assert not calls, calls
    _, calls = run(settings, '--fresh', '--from', 'explicit-base/point')
    assert not calls, calls
    config.unlink()
    os.mkfifo(config)
    try:
        result = subprocess.run([binary, 'create', '--name=check'], env=env,
                                text=True, capture_output=True, timeout=10)
        assert result.returncode != 0 and 'config.json' in result.stderr, result
        assert not calls_file.exists()
    finally:
        config.unlink()
    print('PASS: global config, CLI precedence, fresh/default images, shell quoting, invalid config; fake Incus only')
