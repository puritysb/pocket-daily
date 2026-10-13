"""Negative controls for the short onboarding acceptance report. No device I/O."""
import copy
import unittest
from verify_reader_interface import validate_onboarding_hardware


class OnboardingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.row = dict(platform='macOS', passed=True, initialConnection=True,
                        wifiSetupRollback='passed', screenValidation=dict(passed=True, restored=True),
                        continuityValidation=dict(passed=True, restored=True))

    def test_complete_evidence(self):
        validate_onboarding_hardware([self.row])

    def test_missing_or_failed_evidence_is_not_success(self):
        for records in [[], [{}], [dict(self.row, platform='iOS-device')]]:
            with self.assertRaises(RuntimeError):
                validate_onboarding_hardware(records)
        for field in self.row:
            row = copy.deepcopy(self.row)
            del row[field]
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                validate_onboarding_hardware([row])
        for section in ['screenValidation', 'continuityValidation']:
            for field in ['passed', 'restored']:
                row = copy.deepcopy(self.row)
                row[section][field] = False
                with self.subTest(section=section, field=field), self.assertRaises(RuntimeError):
                    validate_onboarding_hardware([row])


if __name__ == '__main__':
    unittest.main()
