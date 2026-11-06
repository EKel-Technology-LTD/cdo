"""Offline regression for PR 38; does not claim Salesforce runtime validation."""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PERMISSION = Path('force-app/main/default/permissionsets/Case_Resolution_Edit/objectSettings/Case.objectSettings-meta.xml')
TEST = ROOT / 'force-app/main/default/classes/CaseResolutionSummaryGroundingTest.cls'


def check_grant(root):
    fields = root.findall('fieldPermissions')
    names = [field.findtext('field') for field in fields]
    assert len(names) == len(set(names)), 'Duplicate field permissions'
    grants = [field for field in fields if field.findtext('field') == 'Case.AssetId']
    assert len(grants) == 1, 'Missing deployed Case.AssetId grant'
    assert grants[0].findtext('readable') == 'true', 'Lookup must be readable'
    assert grants[0].findtext('editable') == 'false', 'Do not add lookup write access'


check_grant(ET.parse(ROOT / PERMISSION).getroot())
print('PASS: shipped Case.AssetId grant is unique and read-only')
# Mutation controls prove the check catches both the original gap and overgrant.
for mode in ('missing', 'unreadable', 'editable'):
    root = ET.parse(ROOT / PERMISSION).getroot()
    grant = next(f for f in root.findall('fieldPermissions') if f.findtext('field') == 'Case.AssetId')
    if mode == 'missing':
        root.remove(grant)
    else:
        grant.find('readable' if mode == 'unreadable' else 'editable').text = 'false' if mode == 'unreadable' else 'true'
    try:
        check_grant(root)
    except AssertionError:
        print(f'PASS: rejected {mode} grant mutation')
    else:
        raise AssertionError(f'Mutation was not detected: {mode}')

source = TEST.read_text()
assert 'insert new FieldPermissions' not in source
for required in (
    "WHERE Parent.Name = 'Case_Resolution_Edit' AND Field = 'Case.AssetId'",
    'Assert.areEqual(1, assetGrants.size()',
    'Assert.isTrue(assetGrants[0].PermissionsRead',
    'Assert.isFalse(assetGrants[0].PermissionsEdit',
):
    assert required in source, f'Missing Apex regression assertion: {required}'
print('PASS: Apex helper requires deployed grant, not a synthetic FLS shim')
for path in (ROOT / 'force-app').rglob('*.xml'):
    ET.parse(path)
print('PASS: all source XML parses')
