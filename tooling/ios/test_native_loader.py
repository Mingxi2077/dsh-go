import importlib.util
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ios_runtime', Path(__file__).with_name('specialize-runtime.py'))
ios_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios_runtime)


class NativeLoaderTest(unittest.TestCase):
    def test_loads_framework_executables_and_caches_bindings(self):
        original = (ROOT / 'runtime/ohos/native/hap-loader/index.cjs').read_bytes()
        specialized = ios_runtime.native_loader_for_ios(original)
        # Run the real loader against a bundle-shaped directory, intercepting only dlopen.
        script = r'''
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = fs.mkdtempSync(path.join(process.cwd(), '.ios-loader-'));
try {
  const expected = ['DshFlock.framework/DshFlock', 'DshRequireBuiltin.framework/DshRequireBuiltin'];
  for (const relative of expected) {
    const filename = path.join(root, relative);
    fs.mkdirSync(path.dirname(filename));
    fs.writeFileSync(filename, 'native executable fixture');
  }
  const opened = [];
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(0, 'utf8'), {
    require, module,
    process: {
      platform: 'openharmony',
      env: { DSH_GO_OHOS_NATIVE_LIBRARY_DIR: root },
      dlopen(module, filename) { opened.push(filename); module.exports = { loaded: true }; },
    },
  });
  for (const product of ['flock', 'require-builtin']) {
    const result = module.exports.load(product);
    assert.equal(result.binding.loaded, true);
    assert.strictEqual(module.exports.load(product), result);
  }
  assert.deepEqual(opened, expected.map(name => path.join(fs.realpathSync(root), name)));
  assert.throws(() => module.exports.load('unexpected'), { code: 'ERR_OHOS_NATIVE_PRODUCT' });
} finally {
  fs.rmSync(root, { recursive: true });
}
'''
        subprocess.run(['node', '-e', script], input=specialized, cwd=ROOT, check=True)
        self.assertIn(b"flock: 'libdsh_flock.so'", original)

    def test_refuses_a_changed_shared_loader(self):
        with self.assertRaises(ValueError):
            ios_runtime.native_loader_for_ios(b"flock: 'unexpected.so'")


if __name__ == '__main__':
    unittest.main()
