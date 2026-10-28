/** Daily 02:00 LA dispatcher; release action binds the noninteractive scheduling identity. */
public with sharing class SalesTargetActualsSchedulable implements Schedulable {
  public static final String CRON = '0 0 2 * * ?';
  public static final String JOB_NAME = 'Sales Target Daily Actuals';
  private Id machineId;
  /** Captures the authenticated machine, never an arbitrary supplied user ID. */
  public SalesTargetActualsSchedulable() {
    SalesTargetActualsBatch.requirePermission();
    machineId = UserInfo.getUserId();
  }
  /** Scheduled and manual recovery use the same serialized launch path. */
  public void execute(SchedulableContext context) {
    if (machineId != UserInfo.getUserId()) {
      throw new SalesTargetActualsBatch.ActualsException(
        'Sales target scheduler identity changed.'
      );
    }
    launch();
  }
  /** Returns an existing active job rather than starting an overlapping recalculation. */
  public static Id launch() {
    SalesTargetActualsBatch.requirePermission();
    Id actor = UserInfo.getUserId();
    List<User> identityLock = [
      SELECT Id, IsActive, TimeZoneSidKey
      FROM User
      WHERE Id = :actor
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      identityLock.size() != 1 ||
      !identityLock[0].IsActive ||
      identityLock[0].TimeZoneSidKey != 'America/Los_Angeles'
    ) {
      throw new SalesTargetActualsBatch.ActualsException(
        'An active America/Los_Angeles machine is required.'
      );
    }
    List<AsyncApexJob> active = [
      SELECT Id
      FROM AsyncApexJob
      WHERE
        ApexClass.Name = 'SalesTargetActualsBatch'
        AND JobType = 'BatchApex'
        AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!active.isEmpty())
      return active[0].Id;
    return Database.executeBatch(new SalesTargetActualsBatch(), 25);
  }
  /**
   * Separately authorized rollback entry. Stops only the exact owned scheduler;
   * never changes target data, keys, permissions, or unrelated scheduled jobs.
   * @return the stopped CronTrigger ID, or null when no active owned job exists
   */
  public static Id stopOwnedSchedule() {
    SalesTargetActualsBatch.requirePermission();
    Id actor = UserInfo.getUserId();
    List<User> identityLock = [
      SELECT Id
      FROM User
      WHERE Id = :actor
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    List<CronTrigger> jobs = [
      SELECT Id, OwnerId
      FROM CronTrigger
      WHERE
        CronJobDetail.Name = :JOB_NAME
        AND State NOT IN ('DELETED', 'COMPLETE')
      WITH SYSTEM_MODE
    ];
    if (jobs.isEmpty())
      return null;
    if (jobs.size() != 1 || jobs[0].OwnerId != actor) {
      throw new SalesTargetActualsBatch.ActualsException(
        'Rollback schedule ownership is unverified.'
      );
    }
    Id cronId = jobs[0].Id;
    List<AsyncApexJob> bindings = [
      SELECT Id, ApexClass.Name, CreatedById
      FROM AsyncApexJob
      WHERE CronTriggerId = :cronId AND JobType = 'ScheduledApex'
      WITH SYSTEM_MODE
    ];
    if (bindings.isEmpty())
      throw new SalesTargetActualsBatch.ActualsException(
        'Rollback scheduler class is unverified.'
      );
    for (AsyncApexJob binding : bindings) {
      if (
        binding.ApexClass.Name != 'SalesTargetActualsSchedulable' ||
        binding.CreatedById != actor
      )
        throw new SalesTargetActualsBatch.ActualsException(
          'Rollback scheduler class or owner differs.'
        );
    }
    System.abortJob(cronId);
    List<CronTrigger> remaining = [
      SELECT Id
      FROM CronTrigger
      WHERE Id = :cronId AND State NOT IN ('DELETED', 'COMPLETE')
      WITH SYSTEM_MODE
    ];
    if (!remaining.isEmpty())
      throw new SalesTargetActualsBatch.ActualsException(
        'Owned schedule stop is not verified.'
      );
    return cronId;
  }
}
