#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Missing or mismatched target' >&2; exit 1; }
# No Salesforce Setup lock exists. An edit overwritten between final read and deploy
# can be lost without appearing in either snapshot. Never automatically retry or restore.
python3 - "$1" "${BASH_SOURCE[0]}" <<'PY'
import base64
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import xml.dom.minidom as DOM
import xml.etree.ElementTree as ET
import zlib
import zipfile

NS = 'http://soap.sforce.com/2006/04/metadata'
NAME = 'Taiwan_Service_Hours'
API = '67.0'
RISK = ('No exclusive Setup lock: a concurrent edit between final read and deployment '
        'can be overwritten and may be undetectable in readback. Observed drift or '
        'uncertain results stop release. No automatic retry, replay or restoration; '
        'a person must reconcile the live target and separately authorize repair.')
DAYS = ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
EXPECTED = {'active': 'true', 'default': 'false', 'name': NAME, 'timeZoneId': 'Asia/Taipei'}
for day in DAYS[:-1]:
    EXPECTED[day.lower() + 'StartTime'] = '09:00:00.000Z'
    EXPECTED[day.lower() + 'EndTime'] = '12:00:00.000Z' if day == 'Saturday' else '18:00:00.000Z'
BH_MAP = {'name': 'Name', 'active': 'IsActive', 'default': 'IsDefault', 'timeZoneId': 'TimeZoneSidKey'}
for day in DAYS:
    for suffix in ('StartTime', 'EndTime'):
        BH_MAP[day.lower() + suffix] = day + suffix
HOLIDAY_FIELDS = {'Id', 'Name', 'Description', 'IsAllDay', 'ActivityDate', 'StartTimeInMinutes',
                  'EndTimeInMinutes', 'IsRecurrence', 'RecurrenceStartDate', 'RecurrenceEndDateOnly',
                  'RecurrenceType', 'RecurrenceInterval', 'RecurrenceDayOfWeekMask', 'RecurrenceDayOfMonth',
                  'RecurrenceInstance', 'RecurrenceMonthOfYear', 'NextOccurrenceDate'}
AUDIT_FIELDS = {'attributes', 'SystemModstamp', 'LastModifiedDate', 'LastModifiedById', 'LastViewedDate'}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def elements(node, name=None):
    return [c for c in node.childNodes if c.nodeType == c.ELEMENT_NODE
            and (name is None or (c.namespaceURI == NS and c.localName == name))]


def text(node, name):
    found = elements(node, name)
    require(len(found) <= 1, 'Duplicate metadata field: ' + name)
    if not found:
        return None
    require(not elements(found[0]), 'Unexpected nested scalar: ' + name)
    return ''.join(c.data for c in found[0].childNodes if c.nodeType in (c.TEXT_NODE, c.CDATA_SECTION_NODE))


def parse(raw):
    require(b'<!DOCTYPE' not in raw.upper() and b'<!ENTITY' not in raw.upper(), 'DTD/entity declarations refused')
    doc = DOM.parseString(raw)
    require(doc.documentElement.namespaceURI == NS and doc.documentElement.localName == 'BusinessHoursSettings',
            'Wrong settings root or namespace')
    return doc


def projection(raw):
    parse(raw)
    root = ET.fromstring(raw)
    def project(node):
        children = [project(c) for c in node]
        if node is root:
            children.sort(key=lambda c: encoded(c))
        value = node.text if not len(node) or (node.text and node.text.strip()) else None
        tail = node.tail if node.tail and node.tail.strip() else None
        return [node.tag, sorted(node.attrib.items()), value, tail, children]
    return project(root)


def indexed(records):
    require(isinstance(records, list), 'Missing record inventory')
    result = {}
    for record in records:
        name = record.get('Name')
        require(isinstance(name, str) and name and name not in result, 'Missing or duplicate record name')
        require(isinstance(record.get('Id'), str) and len(record['Id']) == 18, 'Missing record identity')
        result[name] = record
    require(len({r['Id'] for r in records}) == len(records), 'Duplicate record identity')
    return result


def record_projection(records):
    return {name: {k: v for k, v in row.items() if k not in AUDIT_FIELDS}
            for name, row in indexed(records).items()}


def scalar(value):
    if isinstance(value, bool):
        return str(value).lower()
    return None if value is None else str(value)


def reconcile(raw, calendars, holidays):
    root = parse(raw).documentElement
    bh = elements(root, 'businessHours')
    hs = elements(root, 'holidays')
    records, holiday_records = indexed(calendars), indexed(holidays)
    names, holiday_names = [text(c, 'name') for c in bh], [text(h, 'name') for h in hs]
    require(len(set(names)) == len(names) and set(names) == set(records), 'Incomplete/ambiguous calendar retrieval')
    require(len(set(holiday_names)) == len(holiday_names) and set(holiday_names) == set(holiday_records),
            'Incomplete/ambiguous holiday retrieval')
    require([r['Name'] for r in calendars if r.get('IsDefault') is True] == ['Default'], 'Unexpected default calendar')
    for entry in bh:
        record = records[text(entry, 'name')]
        for xml_field, field in BH_MAP.items():
            require(field in record and text(entry, xml_field) == scalar(record[field]), 'Calendar metadata/record mismatch: ' + field)
    for holiday in hs:
        name = text(holiday, 'name')
        assignments = [c.firstChild.data if c.firstChild else '' for c in elements(holiday, 'businessHours')]
        require(len(assignments) == len(set(assignments)) and set(assignments) <= set(names), 'Unresolved holiday assignments')
        record = holiday_records[name]
        require(HOLIDAY_FIELDS <= record.keys(), 'Incomplete holiday fields; no write permitted')
        require('ActivityDate' in record and text(holiday, 'activityDate') == record['ActivityDate'], 'Holiday date mismatch')
        require('IsRecurrence' in record, 'Missing holiday recurrence inventory')
        require(text(holiday, 'isRecurring') in (('true',) if record['IsRecurrence'] else (None, 'false')),
                'Holiday recurrence mismatch')
    matches = [entry for entry in bh if text(entry, 'name') == NAME]
    if matches:
        for field, expected in EXPECTED.items():
            require(text(matches[0], field) == expected, 'Existing Taiwan calendar conflicts: ' + field)
        require(text(matches[0], 'sundayStartTime') is None and text(matches[0], 'sundayEndTime') is None,
                'Existing Taiwan calendar is not closed Sunday')
    return bool(matches)


def merge(raw):
    doc = parse(raw)
    root = doc.documentElement
    matches = [e for e in elements(root, 'businessHours') if text(e, 'name') == NAME]
    require(len(matches) <= 1, 'Duplicate Taiwan calendar')
    if matches:
        require(all(text(matches[0], k) == v for k, v in EXPECTED.items())
                and text(matches[0], 'sundayStartTime') is None and text(matches[0], 'sundayEndTime') is None,
                'Conflicting Taiwan calendar')
        return raw, False
    prefix = (root.prefix + ':') if root.prefix else ''
    entry = doc.createElementNS(NS, prefix + 'businessHours')
    for field, value in sorted(EXPECTED.items()):
        child = doc.createElementNS(NS, prefix + field)
        child.appendChild(doc.createTextNode(value))
        entry.appendChild(child)
    calendars = elements(root, 'businessHours')
    require(calendars, 'No baseline calendars')
    root.insertBefore(entry, calendars[-1].nextSibling)
    return doc.toxml(encoding='UTF-8'), True


def compare(before, after, addition=False):
    expected_xml, added = merge(before['xml']) if addition else (before['xml'], False)
    require(projection(expected_xml) == projection(after['xml']), 'Protected metadata or calendar configuration changed')
    require(before['orgId'] == after['orgId'], 'Target organization changed')
    old, new = record_projection(before['calendars']), record_projection(after['calendars'])
    if added:
        require(set(new) == set(old) | {NAME}, 'Calendar membership changed')
        new.pop(NAME)
    require(old == new, 'Protected calendar identities or values changed')
    require(record_projection(before['holidays']) == record_projection(after['holidays']), 'Holiday identities or values changed')


class Action:
    def __init__(self, org, script):
        self.org = org
        self.deadline = time.monotonic() + 840
        self.evidence = pathlib.Path(tempfile.mkdtemp(prefix='taiwan-hours-evidence-', dir='.')).resolve()
        self.org_id = None
        self.job_id = None
        self.submitted = False
        self.sequence = 0
        self.emit('start', {'scriptSha256': digest(pathlib.Path(script).read_bytes()), 'apiVersion': API, 'risk': RISK})

    def emit(self, kind, data):
        self.sequence += 1
        record = {'event': kind, 'time': utc(), 'orgId': self.org_id, 'sequence': self.sequence, 'data': data}
        raw = encoded(record)
        path = self.evidence / ('%03d-%s.json' % (self.sequence, kind))
        path.write_bytes(raw)
        print(json.dumps({'calendarEvidence': record, 'sha256': digest(raw)}), flush=True)

    def sf(self, *args, timeout=90):
        remaining = self.deadline - time.monotonic()
        require(remaining > 5, 'Action time budget exhausted; do not replay')
        env = os.environ.copy()
        env['SF_ORG_API_VERSION'] = API
        result = subprocess.run(['sf', *args, '--target-org', self.org, '--json'], env=env,
                                capture_output=True, text=True, timeout=min(timeout, remaining - 2))
        try:
            receipt = json.loads(result.stdout)
        except (ValueError, TypeError):
            self.emit('command-invalid', {'command': list(args[:3]), 'exitCode': result.returncode})
            raise RuntimeError('Missing/invalid Salesforce JSON; outcome unverified, do not replay')
        self.emit('command', {'command': list(args[:3]), 'exitCode': result.returncode, 'receipt': receipt})
        require(result.returncode == 0 and receipt.get('status') == 0, 'Salesforce command failed; do not replay')
        require(not receipt.get('warnings'), 'Salesforce warnings require reconciliation')
        require(isinstance(receipt.get('result'), dict), 'Missing Salesforce result')
        return receipt['result']

    def query(self, statement):
        result = self.sf('data', 'query', '--query', statement, '--api-version', API)
        require(result.get('done') is True and isinstance(result.get('records'), list)
                and result.get('totalSize') == len(result['records']) and not result.get('nextRecordsUrl'),
                'Incomplete record inventory; no write permitted')
        return result['records']

    def identity(self):
        rows = self.query('SELECT Id, IsSandbox FROM Organization')
        require(len(rows) == 1 and len(rows[0].get('Id', '')) == 18, 'Missing organization identity')
        if self.org_id is None:
            self.org_id = rows[0]['Id']
            self.emit('target', rows[0])
        require(rows[0]['Id'] == self.org_id, 'Authenticated target changed')
        return self.org_id

    def snapshot(self, label):
        org_id = self.identity()
        folder = self.evidence / label
        result = self.sf('project', 'retrieve', 'start', '--metadata', 'Settings:BusinessHours',
                         '--target-metadata-dir', str(folder), '--unzip', '--wait', '5', '--api-version', API, timeout=340)
        require(result.get('done') is True and result.get('success') is True and result.get('status') == 'Succeeded'
                and not result.get('messages') and result.get('id'), 'Incomplete settings retrieval')
        properties = result.get('fileProperties')
        require(isinstance(properties, list) and len([p for p in properties if p.get('type') == 'BusinessHoursSettings'
                and p.get('fullName') == 'BusinessHours']) == 1, 'Missing exact singleton retrieval receipt')
        require(all(p.get('type') in ('BusinessHoursSettings', 'Package') for p in properties), 'Unexpected retrieved component')
        paths = list(folder.rglob('BusinessHours.settings'))
        require(len(paths) == 1 and paths[0].is_file(), 'Missing or ambiguous settings XML')
        raw = paths[0].read_bytes()
        calendars = self.query('SELECT FIELDS(STANDARD) FROM BusinessHours')
        holidays = self.query('SELECT FIELDS(STANDARD) FROM Holiday')
        self.identity()
        self.emit('snapshot', {'label': label, 'retrieveId': result['id'], 'xmlSha256': digest(raw),
                              'xmlZlibBase64': base64.b64encode(zlib.compress(raw)).decode(),
                              'canonical': projection(raw), 'calendars': calendars, 'holidays': holidays})
        exists = reconcile(raw, calendars, holidays)
        return {'orgId': org_id, 'xml': raw, 'calendars': calendars, 'holidays': holidays, 'exists': exists}

    def deploy(self, payload):
        require(self.deadline - time.monotonic() >= 390, 'Insufficient deployment/readback budget; no write attempted')
        self.submitted = True
        # CLI rollbackOnError is true unless --ignore-errors is supplied; never supply it.
        result = self.sf('project', 'deploy', 'start', '--metadata-dir', str(payload), '--single-package',
                         '--async', '--api-version', API, '--test-level', 'NoTestRun', timeout=90)
        self.job_id = result.get('id')
        require(isinstance(self.job_id, str) and re.fullmatch(r'0Af[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?', self.job_id),
                'Missing deployment ID; outcome uncertain, do not replay')
        self.emit('deployment-submitted', {'jobId': self.job_id, 'rollbackOnError': True})
        poll_deadline = min(time.monotonic() + 180, self.deadline - 300)
        while time.monotonic() < poll_deadline:
            result = self.sf('project', 'deploy', 'report', '--job-id', self.job_id, timeout=60)
            require(result.get('id') == self.job_id, 'Wrong deployment job result')
            if result.get('done') is True:
                require(result.get('status') == 'Succeeded' and result.get('success') is True
                        and result.get('rollbackOnError') is True and result.get('checkOnly') is False
                        and result.get('numberComponentErrors') == 0
                        and result.get('numberComponentsDeployed') == result.get('numberComponentsTotal')
                        and result.get('numberComponentsTotal', 0) > 0, 'Deployment failed or partial; do not replay')
                return
            require(result.get('status') in ('Queued', 'Pending', 'InProgress', 'FinalizingDeploy'), 'Unexpected job state; do not replay')
            time.sleep(3)
        raise RuntimeError('Deployment polling deadline exceeded; resolve saved job ID before any authorized retry')

    def run(self):
        before = self.snapshot('before')
        merged, added = merge(before['xml'])
        payload = self.evidence / 'candidate'
        (payload / 'settings').mkdir(parents=True)
        (payload / 'settings' / 'BusinessHours.settings').write_bytes(merged)
        manifest = ('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="' + NS + '">'
                    '<types><members>BusinessHours</members><name>Settings</name></types><version>67.0</version></Package>')
        (payload / 'package.xml').write_text(manifest)
        archive = self.evidence / 'candidate.zip'
        # An explicit ZIP keeps package.xml at the root across CLI directory-packaging versions.
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr('package.xml', manifest)
            bundle.writestr('settings/BusinessHours.settings', merged)
        self.emit('candidate', {'settingsSha256': digest(merged), 'manifestSha256': digest(manifest.encode()),
                                'archiveSha256': digest(archive.read_bytes()), 'add': added})
        fresh = self.snapshot('pre-submit')
        compare(before, fresh)
        if added:
            self.deploy(archive)
        after = self.snapshot('after')
        compare(fresh, after, addition=added)
        require(after['exists'], 'Requested calendar missing after action')
        rerun, would_add = merge(after['xml'])
        require(not would_add and rerun == after['xml'], 'Rerun would mutate settings')
        self.emit('verified', {'added': added, 'jobId': self.job_id, 'protectedProjectionUnchanged': True,
                               'rerunMergeIsNoop': True, 'actualRunnerRerunStillRequired': True,
                               'calendarCount': len(after['calendars']), 'holidayCount': len(after['holidays']), 'risk': RISK})


def main(org, script):
    action = Action(org, script)
    try:
        action.run()
    except Exception as error:
        action.emit('stopped', {'reason': str(error), 'submitted': action.submitted, 'jobId': action.job_id,
                                'automaticRetryAllowed': False, 'risk': RISK})
        if action.submitted and action.deadline - time.monotonic() > 60:
            try:
                action.snapshot('failure-readback')
            except Exception as read_error:
                action.emit('readback-unverified', {'reason': str(read_error)})
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
PY
