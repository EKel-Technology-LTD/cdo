# cdo

Salesforce DX project created with Orchard. CDO is a **sandbox project**: work is built in sandboxes copied from the connected production org, not in scratch orgs.

- `force-app/` holds the metadata. Orchard's pre- and post-deployment actions live in `force-app/scripts/` and `force-app/data/`, under `common/` or `environments/<stage>/` for the release stages in use (QA, UAT).
- `npm ci` installs the lint, format and test tools. `npm run lint`, `npm test` and `npm run prettier:verify` are the checks Orchard's agents run.

Work against a sandbox on your machine:

```bash
sf org login web --instance-url https://test.salesforce.com --alias cdo-sandbox
sf project deploy start --source-dir force-app --target-org cdo-sandbox
```

Orchard hands out development sandboxes from its sandbox pool; use one of those (Orchard → Pools) rather than a production login.

## CI

Pull requests to `main` run Orchard validation via `.github/workflows/pr-validate.yml` (secrets `ORCHARD_URL`, `ORCHARD_CI_TOKEN`). Orchard picks the org that validates each pull request.

### CDO-60 release evidence

After the stage-one metadata installs the mutex object, the operations owner opens **Setup → Sharing Settings** in the target sandbox and verifies that **Grant Access Using Hierarchies** is disabled for **Sales Target Mutex**. Verify this before provisioning its lock record. Keep writers stopped for the approved maintenance window.

Upload the observed setting (for example, a screenshot) as a Salesforce File in that sandbox. Use the title `CDO-60 mutex hierarchy <artifactSha>`, substituting the full approved commit. Share read access with the deployment user. The operations owner must create the version and set its description. Keep one matching file per commit and update its evidence when the approved window changes.

Use this JSON in the file description, substituting the exact values from the release authorization. Use a UTC expiry ending in Z.

```json
{
  "orgId": "<sandbox org ID>",
  "artifactSha": "<40-character approved commit>",
  "targetFingerprint": "<target fingerprint>",
  "approvalReference": "<approved maintenance reference>",
  "expiresAt": "<approved window expiry>",
  "object": "Sales_Target_Mutex__c",
  "grantAccessUsingHierarchies": false
}
```

Both the backfill and the scheduler read this owner attestation before their first write. The release receipt records the Salesforce file version, verifier and timestamp. If evidence is unavailable or mismatched, check the setting and file in the target and resume through the approved release workflow.
