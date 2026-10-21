import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parent.parent / 'scripts' / 'workbench_components.py'
spec = importlib.util.spec_from_file_location('worker', WORKER)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class ComponentContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.archive = self.root / 'archive'
        self.source = self.root / 'fixture.py'
        self.source.write_text('def meaning():\n    return 42\n')
        self.contract = dict(inputs=[], outputs=[], bindings=[], effects=[], unresolved=[], reviewed=True)

    def tearDown(self):
        self.temp.cleanup()

    def register(self, **kwargs):
        return w.register(self.archive, self.source, 'python', 'Return a number', 'function', self.contract, **kwargs)

    def test_python_valid_and_invalid(self):
        self.assertEqual('PASSED', w.parse('python', b'x = 1')['state'])
        self.assertEqual('FAILED', w.parse('python', b'def (')['state'])

    def test_python_body_not_executed(self):
        marker = self.root / 'must-not-exist'
        source = ('from pathlib import Path\nPath(' + repr(str(marker)) + ').touch()\n').encode()
        self.assertEqual('PASSED', w.parse('python', source)['state'])
        self.assertFalse(marker.exists())

    def test_json_strict(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{'):
            self.assertEqual('FAILED', w.parse('json', data)['state'])
        self.assertEqual('PASSED', w.parse('json', b'{"a":1}')['state'])

    def test_xml_rejects_dtd_and_entities(self):
        for data in (b'<!DOCTYPE a [<!ENTITY b "payload">]><a>&b;</a>',
                     '<!DOCTYPE a><a/>'.encode('utf-16')):
            self.assertEqual('FAILED', w.parse('xml', data)['state'])

    def test_xml_wellformed_and_invalid(self):
        self.assertEqual('PASSED', w.parse('xml', b'<a xmlns="urn:test"/>')['state'])
        self.assertEqual('FAILED', w.parse('xml', b'<a>')['state'])

    def test_batch_cmd_do_not_use_shell(self):
        with patch.object(w.subprocess, 'run', side_effect=AssertionError('Must not run')):
            for language in ('batch', 'cmd'):
                self.assertEqual('UNAVAILABLE', w.parse(language, b'del example')['state'])

    def test_missing_runtime_fails_closed(self):
        with patch.object(w.shutil, 'which', return_value=None):
            for language in ('powershell', 'lua', 'javascript'):
                self.assertEqual('UNAVAILABLE', w.parse(language, b'example')['state'])

    def test_adapter_ids_unique_stable(self):
        ids = [w.adapter_id(language) for language in w.LANGUAGES]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(ids[0], w.adapter_id(w.LANGUAGES[0]))

    def test_registered_snapshot_and_gate(self):
        record = self.register()
        report = w.gate(self.archive, record['componentId'], record['version'], self.source)
        self.assertTrue(report['passed'])
        self.assertFalse(report['executionAuthorized'])
        self.assertFalse(report['sourceExecutionPerformed'])

    def test_mutation_of_execution_source_blocks(self):
        record = self.register()
        self.source.write_text('print("changed")')
        report = w.gate(self.archive, record['componentId'], record['version'], self.source)
        self.assertFalse(report['passed'])

    def test_snapshot_tampering_rejected(self):
        record = self.register()
        target = w.location(self.archive, record['componentId'], record['version'])
        (target / record['entryPoint']).write_text('changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            w.gate(self.archive, record['componentId'], record['version'])

    def test_immutable_versions_and_new_revision(self):
        record = self.register()
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.register(component_id=record['componentId'])
        revised = self.register(component_id=record['componentId'], version='1.0.1')
        self.assertEqual(record['componentId'], revised['componentId'])

    def test_unreviewed_or_unresolved_blocks(self):
        self.contract['reviewed'] = False
        record = self.register()
        self.assertFalse(w.gate(self.archive, record['componentId'], record['version'])['passed'])
        self.contract['reviewed'] = True
        self.contract['unresolved'] = ['caller state unknown']
        record = self.register()
        self.assertFalse(w.gate(self.archive, record['componentId'], record['version'])['passed'])

    def test_dependency_pins_and_missing(self):
        child = self.register()
        pin = dict(componentId=child['componentId'], version=child['version'], sha256=child['sha256'])
        parent = self.register(dependencies=[pin])
        self.assertTrue(w.gate(self.archive, parent['componentId'], parent['version'])['passed'])
        pin['sha256'] = '0' * 64
        parent = self.register(dependencies=[pin])
        with self.assertRaisesRegex(ValueError, 'pin mismatch'):
            w.gate(self.archive, parent['componentId'], parent['version'])
        pin['componentId'] = str(w.uuid.uuid4())
        parent = self.register(dependencies=[pin])
        with self.assertRaises(ValueError):
            w.gate(self.archive, parent['componentId'], parent['version'])

    def test_cycle_rejected(self):
        record = self.register()
        target = w.location(self.archive, record['componentId'], record['version']) / 'component.json'
        record['dependencies'] = [dict(componentId=record['componentId'], version=record['version'], sha256=record['sha256'])]
        target.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'Cyclic'):
            w.gate(self.archive, record['componentId'], record['version'])

    def test_path_escape_rejected(self):
        with self.assertRaises(ValueError):
            w.location(self.archive, '../escape', '1.0.0')
        record = self.register()
        target = w.location(self.archive, record['componentId'], record['version']) / 'component.json'
        record['entryPoint'] = '../escape.py'
        target.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'contained'):
            w.load(self.archive, record['componentId'], record['version'])

    def test_lock_prevents_competing_registration(self):
        self.archive.mkdir()
        (self.archive / '.registration-lock').mkdir()
        with self.assertRaisesRegex(ValueError, 'locked'):
            self.register()

    def test_search_does_not_create_archive(self):
        self.assertEqual([], w.search(self.archive, 'number'))
        self.assertFalse(self.archive.exists())
        record = self.register()
        self.assertEqual(record['componentId'], w.search(self.archive, 'number')[0]['componentId'])

    def test_contract_type_validation(self):
        self.contract['reviewed'] = 'true'
        with self.assertRaisesRegex(ValueError, 'boolean'):
            self.register()

    def test_lineage_requires_exact_pins(self):
        with self.assertRaisesRegex(ValueError, 'arrays'):
            self.register(derived_from={'componentId': 'not-a-pin'})

    def test_packaged_parser_catalog_matches_sources(self):
        root = WORKER.parent.parent
        catalog = json.loads((root / 'assets' / 'component-parser-catalog.json').read_text())
        seen = set()
        for entry in catalog['components']:
            self.assertNotIn(entry['componentId'], seen)
            seen.add(entry['componentId'])
            if 'entryPoint' in entry:
                self.assertEqual(entry['sha256'], w.digest((root / entry['entryPoint']).read_bytes()))
            else:
                self.assertEqual('reserved-unavailable', entry['status'])

    def test_javascript_body_not_executed(self):
        if not w.shutil.which('node'):
            self.skipTest('Node unavailable')
        marker = self.root / 'node-must-not-exist'
        code = ('require("fs").writeFileSync(' + json.dumps(str(marker)) + ', "bad");').encode()
        self.assertEqual('PASSED', w.parse('javascript', code, '.cjs')['state'])
        self.assertFalse(marker.exists())
        self.assertEqual('FAILED', w.parse('javascript', b'function {', '.cjs')['state'])


if __name__ == '__main__':
    unittest.main()
