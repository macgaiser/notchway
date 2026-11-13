#!/usr/bin/env python3
"""Writes the fork's translations into Localizable.xcstrings and reports German texts in the
   code that have no English translation yet. Run from the repository root."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from l10n_en import EN, DE
from l10n_scan import FILES

CATALOG = 'boringNotch/Localizable.xcstrings'
INTERP = re.compile(r'\\\((?:[^()"]|\([^()]*\)|"[^"]*")*\)')

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

catalog = json.load(open(CATALOG))
strings = catalog['strings']
for german, english in EN.items():
    variants = [(german, english)]
    if '%@' in german:
        variants.append((german.replace('%@', '%lld'), english.replace('%@', '%lld')))
    for key, value in variants:
        strings.setdefault(key, {}).setdefault('localizations', {}).update({"en": unit(value), "de": unit(key)})
for english, german in DE.items():
    strings.setdefault(english, {}).setdefault('localizations', {})["de"] = unit(german)
json.dump(catalog, open(CATALOG, 'w'), ensure_ascii=False, indent=2, sort_keys=True)

used = set()
for path in FILES:
    for m in re.finditer(r'String\(localized: "((?:[^"\\\n]|\\\((?:[^()"]|\([^()]*\)|"[^"]*")*\)|\\.)*)"\)', open(path).read()):
        used.add(INTERP.sub('%@', m.group(1)))
missing = sorted(used - set(EN))
print(f'{len(EN)} translations; {len(missing)} texts in the code without one')
for text in missing: print('  ', text)
