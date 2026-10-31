"""组装分发站点：校验 IPA → 读取版本信息 → 按内容哈希放置 IPA → 生成 builds.json 与软件源 source.json。

用法：python3 scripts/build_site.py <站点模板目录> <输出目录> <站点根 URL> <变体ID=IPA路径=提交>...
"""
import hashlib
import json
import plistlib
import re
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

PAGES_FILE_LIMIT = 25 * 1024 * 1024  # Cloudflare Pages 单文件上限

VARIANTS = {
    'swiftui': {
        'title': '云析 · 原生版',
        'subtitle': 'SwiftUI 原生实现，体积小、启动快、系统集成度高（推荐）',
        'file': 'YunX.ipa',
    },
    'flutter': {
        'title': '云析 · Flutter 版',
        'subtitle': 'Flutter 跨平台实现，与原生版功能对齐，并行维护',
        'file': 'YunX-Flutter.ipa',
    },
}


def read_ipa(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError(f'{path} 已损坏')
        plist_name = next((n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)), None)
        if plist_name is None:
            raise ValueError(f'{path} 里没有 Payload/*.app/Info.plist')
        info = plistlib.loads(archive.read(plist_name))
    if info.get('CFBundleSupportedPlatforms') not in (['iPhoneOS'], None):
        raise ValueError(f'{path} 不是 iPhone 真机包')
    return info


def main(template: str, out: str, base_url: str, *specs: str) -> None:
    template, out = Path(template), Path(out)
    base_url = base_url.rstrip('/') + '/'
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(template, out)
    now = datetime.now(timezone.utc).isoformat(timespec='seconds')
    builds, apps = [], []
    for spec in specs:
        variant, ipa, commit = spec.split('=', 2)
        meta = VARIANTS[variant]
        ipa = Path(ipa)
        size = ipa.stat().st_size
        if size > PAGES_FILE_LIMIT:
            raise ValueError(f'{ipa} 有 {size} 字节，超过 Cloudflare Pages 单文件 25 MiB 上限')
        info = read_ipa(ipa)
        sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
        # 内容哈希做路径：文件永不变化，可在 CDN 上永久缓存
        rel = f'ipa/{sha[:16]}/{meta["file"]}'
        (out / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ipa, out / rel)
        build = {
            'id': variant,
            'title': meta['title'],
            'subtitle': meta['subtitle'],
            'name': info.get('CFBundleDisplayName') or info.get('CFBundleName') or '云析',
            'bundle': info['CFBundleIdentifier'],
            'version': info.get('CFBundleShortVersionString', '1.0.0'),
            'build': str(info.get('CFBundleVersion', '1')),
            'minimumOS': info.get('MinimumOSVersion', ''),
            'size': size,
            'sha256': sha,
            'commit': commit,
            'path': rel,
            'url': base_url + rel,
            'builtAt': now,
        }
        builds.append(build)
        # 软件源条目：同时写 AltStore 与 ESign 两套字段名，兼容主流自签工具的源格式
        apps.append({
            'name': build['title'],
            'bundleIdentifier': build['bundle'],
            'developerName': 'YunX',
            'subtitle': build['subtitle'],
            'version': build['version'],
            'versionDate': now[:10],
            'versionDescription': f'构建 {build["build"]} · 提交 {commit[:7]}',
            'localizedDescription': build['subtitle'] + '。粘贴网盘 / 视频分享链接，直接高速下载。',
            'downloadURL': build['url'],
            'down': build['url'],
            'iconURL': base_url + 'icon.png',
            'icon': base_url + 'icon.png',
            'tintColor': '4C8BF5',
            'size': size,
            'type': 1,
            'lock': '0',
        })
    (out / 'builds.json').write_text(json.dumps({'updatedAt': now, 'builds': builds}, ensure_ascii=False, indent=2) + '\n',
                                     encoding='utf-8')
    source = {
        'name': '云析 YunX',
        'identifier': 'com.yunx.source',
        'sourceURL': base_url + 'source.json',
        'sourceicon': base_url + 'icon.png',
        'iconURL': base_url + 'icon.png',
        'website': base_url,
        'message': '云析永远免费开源，任何收费版本都是诈骗。',
        'apps': apps,
        'news': [],
    }
    (out / 'source.json').write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(builds, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main(*sys.argv[1:])
