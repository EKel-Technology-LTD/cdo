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
  /**
   * Locks the single org-wide mutex for the entire transaction. Provisioning is
   * a separately authorized release prerequisite; never create a fallback row.
   * SYSTEM_MODE is intentional: no human or machine object CRUD is granted.
   * The row binds the designated machine, not the incidental deployer.
   */
  private static Id acquireMutex() {
    SalesTargetActualsBatch.requirePermission();
    Id actor = UserInfo.getUserId();
    new MutexAccess().acquire();
    List<User> identities = [
      SELECT Id, IsActive, TimeZoneSidKey
      FROM User
      WHERE Id = :actor
      WITH SYSTEM_MODE
    ];
    if (
      identities.size() != 1 ||
      !identities[0].IsActive ||
      identities[0].TimeZoneSidKey != 'America/Los_Angeles'
    ) {
      throw new SalesTargetActualsBatch.ActualsException(
        'An active America/Los_Angeles machine is required.'
      );
    }
    return actor;
  }
  /**
   * Only the system-only lock read bypasses record sharing. A separately
   * authorized provisioner can own the private row; SYSTEM_MODE alone does
   * not remove the outer scheduler's sharing boundary. Never provisions data.
   */
  private without sharing class MutexAccess {
    public void acquire() {
      SalesTargetActualsBatch.requirePermission();
      Id actor = UserInfo.getUserId();
      List<Sales_Target_Mutex__c> locks = [
        SELECT Id, Machine_User__c
        FROM Sales_Target_Mutex__c
        WHERE Lock_Key__c = 'DAILY_ACTUALS'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locks.size() != 1 || locks[0].Machine_User__c != actor) {
        throw new SalesTargetActualsBatch.ActualsException(
          'Sales target mutex is missing or bound to another machine.'
        );
      }
    }
  }
  /** Returns an existing active job rather than starting an overlapping recalculation. */
  public static Id launch() {
    acquireMutex();
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
   * Creates the daily schedule only after the release action has verified its
   * authorization, keys, currency and metadata. Concurrent callers serialize
   * with launch/recovery and stop; existing schedules must be read back, not
   * silently replaced. No persistent mutex provisioning occurs here.
   * @return the new machine-owned CronTrigger ID
   */
  public static Id createOwnedSchedule() {
    acquireMutex();
    Set<Id> boundCronIds = new Set<Id>();
    for (AsyncApexJob binding : [
      SELECT CronTriggerId
      FROM AsyncApexJob
      WHERE
        JobType = 'ScheduledApex'
        AND ApexClass.Name = 'SalesTargetActualsSchedulable'
      WITH SYSTEM_MODE
    ]) {
      if (binding.CronTriggerId != null)
        boundCronIds.add(binding.CronTriggerId);
    }
    List<CronTrigger> existing = [
      SELECT Id
      FROM CronTrigger
      WHERE
        (CronJobDetail.Name = :JOB_NAME
        OR Id IN :boundCronIds)
        AND State NOT IN ('DELETED', 'COMPLETE')
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      throw new SalesTargetActualsBatch.ActualsException(
        'An actuals schedule already exists; read back before retry.'
      );
    }
    return System.schedule(JOB_NAME, CRON, new SalesTargetActualsSchedulable());
  }
  /**
   * Separately authorized rollback entry. Stops only the exact owned scheduler;
   * never changes target data, keys, permissions, or unrelated scheduled jobs.
   * @return the stopped CronTrigger ID, or null when no active owned job exists
   */
  public static Id stopOwnedSchedule() {
    Id actor = acquireMutex();
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
