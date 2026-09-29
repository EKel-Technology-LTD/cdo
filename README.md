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
