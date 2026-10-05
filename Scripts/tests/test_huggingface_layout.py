import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
import stage_model as models
import stage_huggingface as hub
import test_distribution as fixtures


class HuggingFaceLayoutTests(unittest.TestCase):
    def setUp(self):
        fixtures.DistributionTests.setUp(self)
        self.standard = self.root / 'standard'
        models.stage(self.source, self.standard, self.lock)
        self.original_manifest = (self.standard / 'manifest.json').read_bytes()
        self.original_card = (self.standard / 'README.md').read_bytes()
        self.baseline_patch = patch.object(hub, 'BASELINE_MANIFEST_SHA256',
                                          models.checksum(self.standard / 'manifest.json'))
        self.baseline_patch.start()
        self.addCleanup(self.baseline_patch.stop)
        for file in models.PACKAGE_FILES:
            p = self.source / ('decoder_stage_1_multifunction.mlpackage/' + file)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'shared')
        core = json.loads((self.source / 'coreml-only.json').read_text())
        core.update(format='irodori-coreml-only-v2',
            decoder_stage_1_functions={'fixed64':'w64','fixed57':'w57','flexible128':'w128'},
            flexible_decoder_stage_1_package='decoder_stage_1_2d_w128.mlpackage')
        models.write_json(self.source / 'coreml-only.json', core)
        meta = json.loads((self.source / 'text_encoder.json').read_text())
        meta.update(validated_coreml=False, weight_storage='int8-symmetric-block128-float32-compute',
            source_sha256='source', quantization_validation='text_encoder-int8-validation.json',
            source_validation={'package_sha256':'baseline'})
        models.write_json(self.source / 'text_encoder.json', meta)
        models.write_json(self.source / 'text_encoder-int8-validation.json', {
            'format':'irodori-quantized-text-validation-v1',
            'candidatePackageSha256':meta['validated_package_sha256'],
            'baselinePackageSha256':'baseline', 'passed':True, 'sourceOnnxSha256':'source',
            'tokenizerSha256':models.checksum(self.source / 'tokenizer/tokenizer.json'),
            'summary':{'naturalInputCount':24},
            'outputs':[{'case':str(i),'output':key,'relativeL2Percent':1.0,'snrDb':40.0,'cosine':.9999}
                       for i in range(26) for key in ['out_0','out_1']]})
        models.write_json(self.lock, {'format':'irodori-reviewed-artifacts-v1',
            'bundleVersion':'0.2.0-int8','files':models.inventory(self.source)})
        self.light = self.root / 'light'
        models.stage(self.source, self.light, self.lock)
        self.destination = self.root / 'hub-update'

    def tearDown(self):
        self.temp.cleanup()

    def test_overlay_preserves_original_and_keeps_manifests_separate(self):
        standard, light = hub.stage(self.standard, self.light, self.destination)
        hub.verify(self.destination, self.standard)
        self.assertEqual((self.standard / 'manifest.json').read_bytes(), self.original_manifest)
        self.assertEqual((self.standard / 'README.md').read_bytes(), self.original_card)
        baseline = json.loads(self.original_manifest)
        before = {row['path']:row for row in baseline['files']}
        after = {row['path']:row for row in standard['files']}
        self.assertEqual(before.keys(), after.keys())
        self.assertNotEqual(before['README.md'], after['README.md'])
        self.assertEqual({k:v for k,v in before.items() if k != 'README.md'},
                         {k:v for k,v in after.items() if k != 'README.md'})
        self.assertEqual(standard['totalFileBytes'], sum(row['bytes'] for row in standard['files']))
        self.assertFalse(any(row['path'].startswith('int8/') for row in standard['files']))
        self.assertFalse(any(row['path'].startswith('int8/') for row in light['files']))
        for row in light['files']:
            self.assertTrue((self.destination / 'int8' / row['path']).is_file())
        self.assertFalse((self.destination / 'text_encoder.mlpackage').exists())

    def test_stale_root_manifest_and_tampered_card_are_rejected(self):
        hub.stage(self.standard, self.light, self.destination)
        updated = (self.destination / 'manifest.json').read_bytes()
        (self.destination / 'manifest.json').write_bytes(self.original_manifest)
        with self.assertRaisesRegex(ValueError, 'Root manifest'):
            hub.verify(self.destination, self.standard)
        (self.destination / 'manifest.json').write_bytes(updated)
        (self.destination / 'README.md').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Root manifest'):
            hub.verify(self.destination, self.standard)

    def test_private_extra_files_and_changed_int8_weights_are_rejected(self):
        hub.stage(self.standard, self.light, self.destination)
        extra = self.destination / 'recording.wav'
        extra.write_bytes(b'private')
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            hub.verify(self.destination, self.standard)
        extra.unlink()
        weight = self.destination / 'int8/text_encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin'
        weight.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
            hub.verify(self.destination, self.standard)

    def test_unpinned_baseline_is_rejected_before_staging(self):
        with patch.object(hub, 'BASELINE_MANIFEST_SHA256', '0'*64):
            with self.assertRaisesRegex(ValueError, 'original published manifest'):
                hub.stage(self.standard, self.light, self.destination)
        self.assertFalse(self.destination.exists())

    def test_wrong_candidate_version_and_existing_destination_are_rejected(self):
        hub.stage(self.standard, self.light, self.destination)
        with self.assertRaises(FileExistsError):
            hub.stage(self.standard, self.light, self.destination)
        manifest = json.loads((self.light / 'manifest.json').read_text())
        manifest['bundleVersion'] = 'wrong'
        models.write_json(self.light / 'manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'validated light model'):
            hub.stage(self.standard, self.light, self.root / 'wrong-update')


if __name__ == '__main__':
    unittest.main()
