#!/usr/bin/env python3
"""One-off: wraps the user-visible German literals found by l10n_scan in String(localized:)."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from l10n_scan import scan

EXCLUDE = {
    ('GoogleAuth.swift', '<!doctype'), ('GoogleAuth.swift', 'HTTP/1.1'),
    ('IslandMigration.swift', ''), ('IslandTabs.swift', 'Island'),
    ('IslandSettings.swift', '…apps.googleusercontent.com'), ('IslandSettings.swift', 'GOCSPX-…'),
    ('PhoneFiles.swift', '\\(Self.stamp'), ('PhoneFiles.swift', 'Mac'),
    ('PhoneLink.swift', 'Router'), ('PhoneLink.swift', 'Mac'), ('PhoneLink.swift', 'svc 168'),
    ('PhoneLink.swift', 'daemon='), ('PhoneLink.swift', '--- '),
    ('QuickLaunch.swift', 'YouTube Music'), ('SiteIcon.swift', ''), ('PhoneView.swift', '· \\('),
}

def excluded(path, text):
    base = os.path.basename(path)
    return any(base == f and (p == '' or text.startswith(p)) for f, p in EXCLUDE)

edits = {}
for path, line, start, end, text in scan():
    if not excluded(path, text):
        edits.setdefault(path, {}).setdefault(line, []).append((start, end))

for path, lines in edits.items():
    content = open(path).read().split('\n')
    for number, spans in lines.items():
        row = content[number - 1]
        for start, end in sorted(spans, reverse=True):
            row = row[:start] + 'String(localized: ' + row[start:end] + ')' + row[end:]
        content[number - 1] = row
    open(path, 'w').write('\n'.join(content))
    print(path, sum(len(s) for s in lines.values()))
