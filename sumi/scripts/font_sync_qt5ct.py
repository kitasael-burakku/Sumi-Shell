"""Qt 5: reuse the selective QFont editor, preserving Qt 5's own weight/style serialization.

Accept a cross-version theme alias only when the installed Qt 5 plugin declares that key.
Metadata is read as data, never dlopen()ed. cbor2 is optional: no installation or guess if unavailable.
This confirms a configuration route, not the effective font of an arbitrary running application.
"""
import io
import os
from pathlib import Path
import sysconfig

from font_sync_qt6ct import Adapter as Qt6Adapter

SLOTS = {
    'qt5.interface': {'key': 'general', 'cls': 'interface', 'label': 'Qt 5 interface font (qt5ct)'},
    'qt5.fixed': {'key': 'fixed', 'cls': 'code', 'label': 'Qt 5 fixed font (qt5ct)'},
}


def plugin_keys():
    roots = [Path(p) for p in os.environ.get('QT_PLUGIN_PATH', '').split(os.pathsep) if p]
    roots += [Path('/usr/lib/qt/plugins'), Path('/usr/lib64/qt5/plugins'), Path('/usr/lib/qt5/plugins')]
    arch = sysconfig.get_config_var('MULTIARCH')
    if arch:
        roots.append(Path('/usr/lib') / arch / 'qt5/plugins')
    try:
        import cbor2
    except ImportError:
        return [], 'optional cbor2 is unavailable; Qt 5 plugin metadata cannot be checked'
    for root in roots:
        path = root / 'platformthemes/libqt5ct.so'
        try:
            if path.stat().st_size > 16*1024*1024:
                continue
            data = path.read_bytes()
            start = data.index(b'QTMETADATA !')
            # Qt 5 CBOR metadata: 12-byte magic + version/major/minor/arch header; key 4 is MetaData.
            if data[start+12] != 0 or data[start+13] != 5:
                continue
            meta = cbor2.CBORDecoder(io.BytesIO(data[start+16:])).decode()
            if meta.get(2) != 'org.qt-project.Qt.QPA.QPlatformThemeFactoryInterface.5.1':
                continue
            keys = meta.get(4, {}).get('Keys', [])
            if isinstance(keys, list) and keys and all(isinstance(k, str) for k in keys):
                return keys, str(path)
        except (OSError, ValueError, IndexError, AttributeError, cbor2.CBORDecodeError):
            continue
    return [], 'no readable Qt 5 qt5ct plugin metadata in the supported plugin paths'


class Adapter(Qt6Adapter):
    id = 'qt5'
    label = 'Qt 5 (qt5ct)'
    tool = 'qt5ct'
    slots = SLOTS

    def in_use(self):
        pt = os.environ.get('QT_QPA_PLATFORMTHEME', '')
        keys, source = plugin_keys()
        return pt in keys, pt if pt in keys else pt + '; ' + source

    def detect(self):
        info = super().detect()
        keys, source = plugin_keys()
        info.update(pluginKeys=keys, pluginMetadata=source)
        if info.get('state') == 'available':
            info['notes'] = ['Qt 5 apps must use this plugin; process overrides can bypass it',
                             'Reopen apps and verify their effective font; live adoption is unmeasured']
        return info

    def plan(self, slot, choice):
        p = super().plan(slot, choice)
        p['restart'] = 'restart'
        p.setdefault('notes', []).append('Reopen Qt 5 apps; effective font and live adoption need checking')
        return p
