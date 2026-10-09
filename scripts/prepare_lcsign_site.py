"""Verify the built device IPA and publish matching LCSign download metadata."""
import hashlib
import json
import plistlib
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def prepare(ipa, site, commit):
    ipa, site = Path(ipa), Path(site)
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt IPA')
        info = plistlib.loads(archive.read('Payload/YunX.app/Info.plist'))
        if info['CFBundleIdentifier'] != 'com.yunx.app.ios' or info['CFBundleSupportedPlatforms'] != ['iPhoneOS']:
            raise ValueError('Expected YunX iPhone device application')
        if 'Payload/YunX.app/embedded.mobileprovision' in archive.namelist():
            raise ValueError('Expected unsigned IPA')
    metadata = dict(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                    bundle=info['CFBundleIdentifier'], minimumOS=info['MinimumOSVersion'],
                    size=ipa.stat().st_size, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),
                    commit=commit, builtAt=datetime.now(timezone.utc).isoformat(), file='YunX-unsigned.ipa')
    site.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ipa, site / metadata['file'])
    (site / 'build-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (site / 'YunX-unsigned.ipa.sha256').write_text(metadata['sha256'] + '  YunX-unsigned.ipa\n', encoding='utf-8')
    print(json.dumps(metadata, ensure_ascii=False))


if __name__ == '__main__':
    prepare(*sys.argv[1:])
