import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
sys.path.insert(0, str(ROOT / 'Conversion'))
import stage_model as s
from convert_all import commands


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'models'
        self.source.mkdir()
        for name in s.RUNTIME_FILES:
            path = self.source / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'test-model')
        components = {}
        for name in s.AUXILIARY:
            digest = hashlib.sha256()
            for file in sorted(s.PACKAGE_FILES): digest.update(file.encode() + b'\0' + b'test-model')
            sha = digest.hexdigest()
            s.write_json(self.source / (name + '.json'), {'compute_precision':'float32', 'validated_coreml':True, 'validated_package_sha256':sha})
            components[name] = {'package_sha256':sha}
        s.write_json(self.source / 'coreml-only.json', {'format':'irodori-coreml-only-v1', 'components':components})
        digest = hashlib.sha256()
        for file in sorted(s.PACKAGE_FILES): digest.update(file.encode() + b'\0' + b'test-model')
        s.write_json(self.source / 'audioseal.json', {'format':'irodori-audioseal-v1','precision':'float32',
            'validatedCoreML':True,'packages':{name:digest.hexdigest() for name in ['audioseal_generator','audioseal_detector']}})
        self.lock = self.root / 'lock.json'
        s.write_json(self.lock, {'format':'irodori-reviewed-artifacts-v1','bundleVersion':'test','files':s.inventory(self.source)})
    def tearDown(self): self.temp.cleanup()

    def test_stage_excludes_private_files_and_detects_tampering(self):
        (self.source / 'private.wav').write_bytes(b'private voice')
        (self.source / 'secret.env').write_bytes(b'private data')
        destination = self.root / 'bundle'
        s.stage(self.source, destination, self.lock)
        self.assertFalse((destination / 'private.wav').exists())
        self.assertFalse((destination / 'secret.env').exists())
        manifest = s.verify(destination)
        self.assertGreater(len(manifest['files']), len(s.RUNTIME_FILES))
        provenance = json.loads((destination / 'provenance.json').read_text())
        self.assertEqual(manifest['bundleVersion'], 'test')
        self.assertEqual(provenance['bundleVersion'], manifest['bundleVersion'])
        self.assertEqual(provenance['runtimeVersion'], '0.1.0')
        for name in ['LICENSE_REVIEW.md', 'license-review.json']:
            self.assertIn(name, {row['path'] for row in manifest['files']})
        evidence = json.loads((destination / 'license-review.json').read_text())
        self.assertEqual(evidence['dacvaeClarification']['discussionUrl'],
                         'https://huggingface.co/facebook/dacvae-watermarked/discussions/1')
        self.assertEqual(evidence['dacvaeClarification']['appliesTo'],
                         'model weights, in response to an explicit weights-license question')
        (destination / 'config.json').write_bytes(b'modified')
        with self.assertRaises(ValueError): s.verify(destination)

    def test_mismatched_source_does_not_create_destination(self):
        (self.source / 'tokenizer/tokenizer.json').write_bytes(b'changed tokenizer')
        with self.assertRaises(ValueError): s.stage(self.source, self.root / 'bundle', self.lock)
        self.assertFalse((self.root / 'bundle').exists())

    def test_unvalidated_auxiliary_is_rejected(self):
        (self.source / 'speaker_encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin').write_bytes(b'changed weights')
        with self.assertRaises(ValueError): s.inventory(self.source)

    def test_unvalidated_watermark_is_rejected(self):
        (self.source / 'audioseal_generator.mlpackage/Data/com.apple.CoreML/weights/weight.bin').write_bytes(b'changed weights')
        with self.assertRaises(ValueError): s.inventory(self.source)

    def test_symlink_and_traversal_are_rejected(self):
        (self.source / 'escape').symlink_to(self.root)
        for name in ['../lock.json', '/etc/passwd', 'a//b', 'escape/lock.json']:
            with self.assertRaises((ValueError,FileNotFoundError)): s.safe_file(self.source, name)

    def test_existing_destination_and_unlisted_files_are_rejected(self):
        destination = self.root / 'bundle'
        s.stage(self.source, destination, self.lock)
        with self.assertRaises(FileExistsError): s.stage(self.source, destination, self.lock)
        (destination / 'extra.wav').write_bytes(b'private')
        with self.assertRaises(ValueError): s.verify(destination)

    def test_conversion_commands_use_single_package_validation_argument(self):
        recipe = list(commands(Path('sources'), Path('output')))
        validations = [row for row in recipe if row[1].endswith('validate_coreml_auxiliary.py')]
        self.assertEqual(len(validations), 7)
        self.assertTrue(all(len(row) == 3 and row[2].endswith('.mlpackage') for row in validations))
        self.assertEqual(sum(row[1].endswith('export_coreml_decoder_2d.py') for row in recipe), 5)


if __name__ == '__main__': unittest.main()
