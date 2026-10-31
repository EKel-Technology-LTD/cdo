/** Native Field Generation grounding only. Never writes records or invokes a model. */
public with sharing class CaseResolutionSummaryGrounding {
  private static final String FAILURE = '無法準備案件摘要，請確認存取權限與案件資料。';
  public class PreparationException extends Exception {
  }
  public class Request {
    @InvocableVariable(required=true)
    public Case RelatedEntity;
  }
  public class Response {
    @InvocableVariable
    public String Prompt;
  }
  @InvocableMethod(
    label='案件摘要資料準備'
    CapabilityType='PromptTemplateType://einstein_gpt__fieldCompletion'
  )
  public static List<Response> prepare(List<Request> requests) {
    try {
      if (
        !authorized(
          FeatureManagement.checkPermission('Case_Summary_Generation'),
          Case.SObjectType.getDescribe().isAccessible(),
          Case.SObjectType.getDescribe().isUpdateable(),
          Case.Resolution_Summary__c.getDescribe().isUpdateable()
        ) ||
        requests == null ||
        requests.isEmpty() ||
        requests.size() > 200
      )
        throw new PreparationException(FAILURE);
      Set<Id> ids = new Set<Id>();
      for (Request request : requests) {
        if (
          request == null ||
          request.RelatedEntity == null ||
          request.RelatedEntity.Id == null ||
          request.RelatedEntity.Id.getSObjectType() != Case.SObjectType
        )
          throw new PreparationException(FAILURE);
        ids.add(request.RelatedEntity.Id);
      }
      Id userId = UserInfo.getUserId();
      Set<Id> editable = new Set<Id>();
      for (UserRecordAccess access : [
        SELECT RecordId, HasEditAccess
        FROM UserRecordAccess
        WHERE UserId = :userId AND RecordId IN :ids
        WITH USER_MODE
      ]) {
        if (access.HasEditAccess)
          editable.add(access.RecordId);
      }
      if (editable.size() != ids.size())
        throw new PreparationException(FAILURE);
      // Child LIMITs apply separately to each case, not to the combined input batch.
      // Persisted Ids alone are trusted. No customer/owner/technician traversal.
      Map<Id, String> prompts = new Map<Id, String>();
      Integer preparedCharacters = 0;
      // Stream parents; retain only sanitized output, not a map of raw records.
      for (Case c : [
        SELECT
          Id,
          Subject,
          Description,
          Product_Line__c,
          Status,
          Priority,
          Resolution_Code__c,
          CreatedDate,
          AssetId,
          Asset.Product2Id,
          Asset.Product2.Name,
          Asset.Product2.Model_Number__c,
          Asset.Warranty_Status__c,
          (
            SELECT
              Name,
              Repair_Status__c,
              Fault_Category__c,
              Diagnosis_Result__c,
              Warranty_Coverage__c,
              Total_Charge__c,
              Repair_Completed_Date__c,
              Shipped_Back_Date__c
            FROM Repair_Orders__r
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 3
          ),
          (
            SELECT CommentBody
            FROM CaseComments
            WHERE IsPublished = TRUE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 5
          ),
          (
            SELECT TextBody
            FROM EmailMessages
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 5
          )
        FROM Case
        WHERE Id IN :ids
        WITH USER_MODE
      ]) {
        if (Limits.getHeapSize() > Limits.getLimitHeapSize() * 3 / 4)
          throw new PreparationException(FAILURE);
        Map<String, Object> root = new Map<String, Object>();
        List<String> omissions = new List<String>();
        Map<String, Object> caseFacts = new Map<String, Object>();
        text(caseFacts, 'subject', c.Subject, 32000, omissions);
        text(caseFacts, 'description', c.Description, 32000, omissions);
        text(caseFacts, 'productLine', c.Product_Line__c, 255, omissions);
        text(caseFacts, 'status', c.Status, 255, omissions);
        text(caseFacts, 'priority', c.Priority, 255, omissions);
        text(caseFacts, 'resolutionCode', c.Resolution_Code__c, 255, omissions);
        caseFacts.put('createdAt', fact(c.CreatedDate));
        root.put('case', caseFacts);
        Map<String, Object> product = new Map<String, Object>();
        if (c.AssetId != null) {
          text(
            product,
            'warrantyStatus',
            c.Asset.Warranty_Status__c,
            255,
            omissions
          );
          if (c.Asset.Product2Id != null) {
            text(product, 'name', c.Asset.Product2.Name, 255, omissions);
            text(
              product,
              'model',
              c.Asset.Product2.Model_Number__c,
              40,
              omissions
            );
          }
        }
        root.put('product', product);
        List<Object> repairs = new List<Object>();
        for (Repair_Order__c repair : c.Repair_Orders__r) {
          Map<String, Object> item = new Map<String, Object>{
            'number' => repair.Name,
            'amount' => fact(repair.Total_Charge__c),
            'completedDate' => fact(repair.Repair_Completed_Date__c),
            'returnShippingDate' => fact(repair.Shipped_Back_Date__c)
          };
          text(item, 'repairStatus', repair.Repair_Status__c, 255, omissions);
          text(item, 'faultCategory', repair.Fault_Category__c, 255, omissions);
          text(
            item,
            'inspectionResult',
            repair.Diagnosis_Result__c,
            4000,
            omissions
          );
          text(
            item,
            'warrantyDetermination',
            repair.Warranty_Coverage__c,
            255,
            omissions
          );
          repairs.add(item);
        }
        root.put('repairs', repairs);
        List<String> comments = new List<String>();
        for (CaseComment comment : c.CaseComments)
          addEntry(comments, comment.CommentBody, 'comment', omissions);
        root.put('comments', comments);
        List<String> emails = new List<String>();
        for (EmailMessage email : c.EmailMessages)
          addEntry(emails, email.TextBody, 'email', omissions);
        root.put('emails', emails);
        root.put('omittedEntries', omissions);
        root.put(
          'missingFactRule',
          'null 或缺少欄位代表未知；omittedEntries 代表已略過資料，不代表沒有維修或金額為零。'
        );
        String prepared = JSON.serialize(root);
        preparedCharacters += prepared.length();
        // Fail closed on unusually large batches without truncating facts or source rows.
        if (preparedCharacters > 1000000)
          throw new PreparationException(FAILURE);
        prompts.put(c.Id, prepared);
      }
      if (prompts.size() != ids.size())
        throw new PreparationException(FAILURE);
      List<Response> responses = new List<Response>();
      for (Request request : requests) {
        Response response = new Response();
        response.Prompt = prompts.get(request.RelatedEntity.Id);
        responses.add(response);
      }
      return responses;
    } catch (Exception ignored) {
      // Never log source, exception messages, prompt content or identifiers.
      throw new PreparationException(FAILURE);
    }
  }
  @TestVisible
  private static Boolean authorized(
    Boolean feature,
    Boolean readCase,
    Boolean editCase,
    Boolean editSummary
  ) {
    return feature == true &&
      readCase == true &&
      editCase == true &&
      editSummary == true;
  }
  private static void text(
    Map<String, Object> target,
    String key,
    String value,
    Integer cap,
    List<String> omissions
  ) {
    String safe = safeText(value, cap);
    if (value != null && safe == null)
      omissions.add(key);
    target.put(key, safe);
  }
  private static void addEntry(
    List<String> target,
    String value,
    String kind,
    List<String> omissions
  ) {
    String safe = safeText(value, 1000);
    if (value != null && safe == null)
      omissions.add(kind);
    else if (safe != null)
      target.add(safe);
  }
  @TestVisible
  private static String fact(Object value) {
    if (value == null)
      return null;
    if (value instanceof Datetime)
      return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    if (value instanceof Date) {
      Date d = (Date) value;
      return String.valueOf(d.year()) +
        '-' +
        String.valueOf(d.month()).leftPad(2, '0') +
        '-' +
        String.valueOf(d.day()).leftPad(2, '0');
    }
    return String.valueOf(value);
  }
  @TestVisible
  private static String safeText(String source, Integer cap) {
    if (source == null)
      return null;
    // Inspect the entire entry, never merely the visible 1,000-character prefix.
    // Conservative omission is intentional; detection is not a universal PII guarantee.
    if (source.length() > 32768 || cap == null || cap < 1)
      return null;
    List<Integer> normalized = new List<Integer>();
    for (Integer i = 0; i < source.length(); i++) {
      Integer point = source.charAt(i);
      if (
        point == 65533 ||
        (point >= 55296 &&
        point <= 57343) ||
        (point < 32 &&
        point != 9 &&
        point != 10 &&
        point != 13)
      )
        return null;
      if (point >= 65281 && point <= 65374)
        point -= 65248;
      if (point == 12288 || point == 160)
        point = 32;
      if (
        (point >= 8203 &&
        point <= 8207) ||
        (point >= 8234 &&
        point <= 8238) ||
        (point >= 8288 &&
        point <= 8297) ||
        point == 65279
      )
        continue;
      normalized.add(point);
    }
    String detection = String.fromCharArray(normalized)
      .toLowerCase()
      .replaceAll('[\\s\\p{Z}]+', '');
    if (
      Pattern.compile('&[^;]{1,20};|%[0-9a-f]{2}').matcher(detection).find() ||
      detection.contains('\\u') ||
      detection.contains('@') ||
      detection.contains('＠') ||
      detection.replaceAll('[^0-9]', '').length() >= 7 ||
      Pattern.compile('[\\p{N}]')
        .matcher(detection.replaceAll('[0-9]', ''))
        .find() ||
      Pattern.compile(
          '內部|内部|技師|技师|technician|internal|姓名|名字|客戶名|客户名|聯絡人|联系人|name:|customername|電話|电话|手機|手机|phone|tel:|地址|住址|address|發票|发票|invoice|身分|身份|passport|身分證|身份证|ignore|instruction|systemprompt|disclose|reveal|忽略|指令|提示詞|提示词|洩漏|泄露|請輸出|请输出'
        )
        .matcher(detection)
        .find() ||
      Pattern.compile(
          '[市縣县].{0,30}[路街鄉乡鎮镇區区]|[路街].{0,12}[號号樓楼]|[0-9]+[a-z]+(street|road|avenue)'
        )
        .matcher(detection)
        .find()
    )
      return null;
    return source.length() > cap ? source.substring(0, cap) : source;
  }
}
