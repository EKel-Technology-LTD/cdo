# Sales target calculations

CDO-60 deploys the Salesforce Apex class `SalesTargetActualsSchedulable` and its calculation batch. Deployment is complete independently of whether a schedule exists. The customer decides whether and when to run the calculation.

The customer's Salesforce administrator owns scheduling. Check **Setup → Scheduled Jobs** for an existing sales target job before adding one. Keep an existing job whose cadence meets the business need, or manage its replacement through the organization's normal scheduling process. Deployment does not inspect or alter existing jobs.

The calculation uses the scheduling identity when it runs. Its current access controls require the designated automation user, the sales target system-write permission and the matching mutex record. The class also checks the America/Los_Angeles time zone. A job created under an ordinary user's personal login will fail these checks. Use the organization's authorized automation identity if enabling the job. The migration credential is required for the separate release operation that grants access and backfills existing target keys.
