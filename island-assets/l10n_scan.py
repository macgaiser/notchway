#!/usr/bin/env python3
"""Finds the user-visible German string literals in the fork's own Swift files.
   scan(): yields (file, line number, start, end, literal text) for each candidate."""
import re, glob

FILES = sorted(glob.glob('boringNotch/Island/**/*.swift', recursive=True))
LIT = re.compile(r'"((?:[^"\\\n]|\\\((?:[^()"]|\([^()]*\)|"[^"]*")*\)|\\.)*)"')
SKIP_LINE = re.compile(r'^\s*(//|///)|Key<|forKey|print\(|NSLog|dateFormat|\blog\(|identifier:|Notification\.Name|forHTTPHeaderField|#"|^\s*case "|static let \w+(ID|Title|Name|Space|Category|Action)\b|thread\.name|\.name = "|queryItems|URLQueryItem|private static let (space|folderName|formerBundleID)')
# Literals that are identifiers or data, not text for the user.
NOT_TEXT = re.compile(r'^(island[\w.\-]*|[a-z][\w.\-]*|https?:.*|[A-Z_]{3,}|.*\.(sock|json|log|plist|png|jpg|mp4|svg)|Bearer .*|application/.*|Content-Type|Authorization|GET|POST|PATCH|DELETE|[\w.]+@[\w.]+)$')

def is_text(t):
    if len(t) < 2 or NOT_TEXT.match(t): return False
    if t.startswith('\\(') and t.endswith(')') and t.count('\\(') == 1: return False
    plain = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '', t)
    if re.search(r'[äöüÄÖÜß…„“·]', plain): return True
    if ' ' in plain.strip() and re.search(r'[A-Za-zäöü]{3}', plain): return True
    return bool(re.match(r'^[A-ZÄÖÜ][a-zäöüß\-]{2,}[.:!?]?$', plain.strip()))

def scan():
    for f in FILES:
        block = False
        for n, line in enumerate(open(f).read().split('\n'), 1):
            if line.count('"""') % 2 == 1:
                block = not block
                continue
            if block or SKIP_LINE.search(line): continue
            for m in LIT.finditer(line):
                before = line[:m.start()]
                if before.endswith('localized: ') or before.rstrip().endswith(('==', '!=', 'systemName:', 'systemImage:', 'icon:', 'named:', 'forType:', 'withExtension:')): continue
                if is_text(m.group(1)):
                    yield f, n, m.start(), m.end(), m.group(1)

if __name__ == '__main__':
    last = None
    for f, n, s, e, t in scan():
        if f != last: print('##', f); last = f
        print(f'{n}\t{t}')
