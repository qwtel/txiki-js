import assert from 'tjs:assert';
import path from 'tjs:path';

// Must run out of process: a static import of an unregistered tjs: module
// aborts the whole script, so it cannot be probed with try / catch.
const args = [
    tjs.exePath,
    'run',
    path.join(import.meta.dirname, 'helpers', 'import-unknown-builtin.js')
];
const proc = tjs.spawn(args, { stdout: 'pipe', stderr: 'pipe' });
const [ status, stdout, stderr ] = await Promise.all([
    proc.wait(),
    proc.stdout.text(),
    proc.stderr.text()
]);

assert.ok(status.exit_status !== 0 && status.term_signal === null, 'importing an unknown tjs: module fails the process');
assert.ok(stderr.includes('ReferenceError'), 'the failure is a ReferenceError');
assert.ok(stderr.includes('tjs:doesnotexist'), 'the error names the specifier');
assert.ok(!stdout.includes('reached'), 'the script does not run past the failed import');
