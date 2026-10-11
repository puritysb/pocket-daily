#!/usr/bin/env python3
"""Unattended app regression + enrolled physical-reader interface acceptance.

Uses the firmware-owned runner; does not install firmware or change Wi-Fi.
See docs/READER_INTERFACE_VALIDATION.md for coverage and initial prerequisites.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def simulator_id():
    listing = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    phones = [d for devices in listing['devices'].values() for d in devices
              if d['name'].startswith('iPhone')]
    phones.sort(key=lambda d: (d['state'] != 'Booted', d['name']))
    if not phones:
        raise RuntimeError('An installed iPhone simulator is required')
    return phones[0]['udid']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firmware-repo', type=Path, default=ROOT.parent / 'pocket-daily-firmware')
    parser.add_argument('--physical-only', action='store_true', help='never invoke a simulator or simulator screenshots')
    parser.add_argument('--screen-suite', action='store_true', help='capture and validate physical X3 Home/Brief pixels')
    parser.add_argument('--simulator', help='iPhone simulator UDID; defaults to an available iPhone')
    parser.add_argument('--ios-device', help='also run all supported cases on this physical iPhone UDID')
    parser.add_argument('--standby', action='store_true', help='also verify X3 experimental BLE standby/wake')
    parser.add_argument('--screenshots', action='store_true', help='regenerate iPhone/iPad/Mac UI captures')
    args = parser.parse_args()
    if args.physical_only and (args.simulator or args.screenshots):
        parser.error('--physical-only cannot be combined with simulator or app screenshot options')
    firmware = args.firmware_repo.resolve()
    runner = firmware / 'scripts/dev_pipeline.py'
    if not runner.is_file():
        parser.error('Firmware developer pipeline not found in the sibling checkout')
    sys.path.insert(0, str(runner.parent))
    spec = importlib.util.spec_from_file_location('reader_pipeline', runner)
    pipeline = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pipeline)
    name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S-%f')
    output = ROOT / '.build/interface-runs' / name
    with pipeline.exclusive(ROOT / '.build/reader-interface.lock'):
        job = pipeline.Pipeline(output)
        print('Report: ' + str(output / 'report.json'), flush=True)
        job.report['scope'] = 'Automated regression and enrolled-reader Same Wi-Fi interfaces'
        job.report['notEstablished'] = ['X4 hardware (unless enrolled)', 'iCloud between physical Apple devices',
            'Direct Wi-Fi association and OS permission dialogs', 'physical SD mount and removal',
            'reader button/display optics and accepting a reading-position offer', 'App Store release readiness']
        job.report['appSources'] = pipeline.source_state(ROOT)
        try:
            job.stage('exclusive-app-preflight', pipeline.require_companion_stopped)
            job.command('project', ['xcodegen', 'generate'], cwd=ROOT)
            if not args.physical_only:
                sim = args.simulator or job.stage('simulator', simulator_id)
                job.command('app-unit-tests', ['xcodebuild', 'test', '-quiet', '-project', 'Pocket.xcodeproj',
                    '-scheme', 'Pocket', '-destination', 'platform=iOS Simulator,id=' + sim,
                    '-derivedDataPath', str(ROOT / '.build/tests'), 'CODE_SIGNING_ALLOWED=NO',
                    '-only-testing:PocketTests', '-resultBundlePath', str(output / 'unit.xcresult')], cwd=ROOT)
            else:
                job.report['iosUnitTests'] = 'not run: physical-only scope'
            job.command('mac-reader-tests', ['xcodebuild', 'test', '-quiet', '-project', 'Pocket.xcodeproj',
                '-scheme', 'PocketMac', '-destination', 'platform=macOS,arch=arm64',
                '-derivedDataPath', str(ROOT / '.build/interface-mac'), 'CODE_SIGNING_ALLOWED=YES',
                '-only-testing:PocketMacTests/PocketMacReaderTests',
                '-only-testing:PocketMacTests/DeviceSnapshotTests',
                '-only-testing:PocketMacTests/ReaderShelfTests',
                '-only-testing:PocketMacTests/ReaderInventoryModelTests',
                '-only-testing:PocketMacTests/ReaderFileDownloaderTests',
                '-only-testing:PocketMacTests/ReaderFilePieceRequestTests',
                '-only-testing:PocketMacTests/ReaderBluetoothLinkTests',
                '-only-testing:PocketMacTests/ReadingSyncBLEProtocolTests',
                '-only-testing:PocketMacTests/ReaderWakeConnectorTests',
                '-only-testing:PocketMacTests/ReaderWiFiSetupTests',
                '-only-testing:PocketMacTests/ReaderScreenCaptureTests',
                '-resultBundlePath', str(output / 'reader.xcresult')], cwd=ROOT,
                env={**os.environ, 'TEST_RUNNER_POCKET_EPUB_SAMPLES':
                     str(firmware / 'test/reading_progress/fixtures')})
            command = [sys.executable, str(runner), 'run', '--app', str(ROOT), '--interface-suite']
            if args.screen_suite:
                command.append('--screen-suite')
            if args.standby:
                command.append('--standby')
            if args.ios_device:
                command += ['--ios-device', args.ios_device]
            log = job.command('physical-interface', command, cwd=ROOT, timeout=2400)
            reports = [line.removeprefix('Report: ') for line in log.read_text().splitlines()
                       if line.startswith('Report: ')]
            if len(reports) != 1:
                raise RuntimeError('Physical interface report is missing or ambiguous')
            evidence = json.loads(Path(reports[0]).read_text())
            if evidence.get('passed') is not True or not evidence.get('hardware'):
                raise RuntimeError('Physical interface did not produce passing hardware evidence')
            job.report['hardwareReport'] = reports[0]
            job.report['hardware'] = evidence['hardware']
            job.report['iosPhysical'] = evidence['iosPhysical']
            if args.screenshots:
                # Full UI flows run on both simulator sizes before Mac capture.
                job.command('screenshots', ['./scripts/capture_screenshots.sh'], cwd=ROOT, timeout=3600,
                    env={**os.environ, 'POCKET_SCREENSHOT_TEST_TARGET': 'PocketUITests',
                         'POCKET_SCREENSHOT_PLATFORMS': 'iphone ipad mac',
                         'POCKET_SCREENSHOT_REPORT_DIR': str(output / 'ui-results')})
                job.report['uiResults'] = {name: json.loads((output / 'ui-results' / (name + '.json')).read_text())
                                           for name in ['iphone-6.9', 'ipad-13', 'mac-16x10']}
            job.command('package-validation', ['./scripts/validate_app_store.sh'], cwd=ROOT)
            job.command('diff-check', ['git', 'diff', '--check'], cwd=ROOT)
            job.report['passed'] = True
        except Exception as error:
            job.report['error'] = str(error)
            print('FAILED: ' + str(error), file=sys.stderr)
            return 1
        finally:
            job.flush()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
