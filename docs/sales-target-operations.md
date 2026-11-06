# Sales target actuals operations

CDO-60 deploys `SalesTargetActualsSchedulable` and its calculation batch. The approved activation action registers the daily 02:00 America/Los_Angeles schedule using Orchard's separately authenticated machine identity, after the existing release authorization, hierarchy evidence, protections, key and currency gates pass. Missing release inputs block execution, not source preparation.

Activation reuses only one healthy job matching the name, cadence, timezone, machine owner and Apex class binding. Missing jobs are registered through `createOwnedSchedule()`, whose mutex lock and duplicate check serialize concurrent callers. Activation reads the schedule back before reporting success. Conflicting, paused or unverifiable jobs block without replacement; uncertain writes must be inspected before a separately authorized rerun.

The machine needs `Sales_Target_System_Write_Access`, the matching pre-provisioned DAILY_ACTUALS mutex and America/Los_Angeles timezone. Ordinary users must not schedule this job under their personal login. No human identity is substituted for the machine and this rework grants no org access or release authorization.

The recurring native entry is `SalesTargetActualsSchedulable.execute()` → `launch()` → `SalesTargetActualsBatch` (scope 25). It never launches or depends on a delivery script. Monitor Scheduled Jobs and Apex Jobs; retain the activation receipt's schedule ID. Recovery and rollback remain separately authorized operations through the existing guarded native helpers, not automatic deployment retries. Writers remain quiesced until the authorized operations owner ends the approved window.
