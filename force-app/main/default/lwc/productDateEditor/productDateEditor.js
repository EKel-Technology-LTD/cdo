import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { CloseActionScreenEvent } from "lightning/actions";
import { getObjectInfo } from "lightning/uiObjectInfoApi";
import { getLayout } from "lightning/uiLayoutApi";
import {
  getRecord,
  getRecordCreateDefaults,
  createRecord,
  updateRecord,
  notifyRecordUpdateAvailable
} from "lightning/uiRecordApi";
import TIME_ZONE from "@salesforce/i18n/timeZone";

const DATE_FIELDS = ["AvailabilityDate", "DiscontinuedDate"];
const DATE_ERROR = "停售日期不可早於上市日期。";
export default class ProductDateEditor extends NavigationMixin(
  LightningElement
) {
  @api recordId;
  info;
  layout;
  record;
  defaults;
  routeCreate = false;
  selectedRecordType;
  changes = {};
  busy = false;
  uncertain = false;
  error = "";
  fieldErrors = {};
  timezone = TIME_ZONE;
  loadedRecordId;
  baselineModified;

  @wire(CurrentPageReference) pageReference({ state } = {}) {
    this.routeCreate = state?.c__mode === "create";
  }
  @wire(getObjectInfo, { objectApiName: "Product2" }) objectInfo({
    data,
    error
  }) {
    if (data) this.info = data;
    if (error) this.error = this.message(error);
  }
  @wire(getRecord, {
    recordId: "$recordId",
    layoutTypes: ["Full"],
    modes: ["Edit"],
    optionalFields: [
      "Product2.LastModifiedDate",
      "Product2.AvailabilityDate",
      "Product2.DiscontinuedDate"
    ]
  })
  recordData({ data, error }) {
    if (
      data &&
      data.apiName === "Product2" &&
      data.id !== this.loadedRecordId
    ) {
      this.record = data;
      this.loadedRecordId = data.id;
      this.baselineModified = data.fields.LastModifiedDate?.value;
    }
    if (error) this.error = this.message(error);
  }
  get createObject() {
    return this.isCreate && this.info?.createable ? "Product2" : undefined;
  }
  @wire(getRecordCreateDefaults, {
    objectApiName: "$createObject",
    recordTypeId: "$recordTypeId"
  })
  createDefaults({ data, error }) {
    if (data) this.defaults = data.record;
    if (error) this.error = this.message(error);
  }
  @wire(getLayout, {
    objectApiName: "Product2",
    layoutType: "Full",
    mode: "$layoutMode",
    recordTypeId: "$recordTypeId"
  })
  layoutData({ data, error }) {
    if (data) this.layout = data;
    if (error) this.error = this.message(error);
  }
  get isCreate() {
    return !this.recordId && this.routeCreate;
  }
  get layoutMode() {
    return this.recordId ? "Edit" : "Create";
  }
  get recordTypeId() {
    return (
      this.record?.recordTypeId ||
      this.selectedRecordType ||
      this.info?.defaultRecordTypeId
    );
  }
  get title() {
    return this.recordId ? "Edit Product" : "Create Product";
  }
  get allowed() {
    return !!(
      this.info &&
      (this.recordId
        ? this.info.updateable && this.record
        : this.isCreate && this.info.createable)
    );
  }
  get ready() {
    return !!(
      this.allowed &&
      this.layout &&
      (this.recordId ? this.record : this.defaults)
    );
  }
  get denied() {
    return (
      !!this.info &&
      !(this.recordId
        ? this.info.updateable
        : this.isCreate && this.info.createable)
    );
  }
  get showSpinner() {
    return this.busy || (!this.ready && !this.denied && !this.error);
  }
  get disabled() {
    return this.busy || this.uncertain;
  }
  get recordTypeOptions() {
    return Object.entries(this.info?.recordTypeInfos || {})
      .filter(([, v]) => v.available && !v.master)
      .map(([value, v]) => ({ value, label: v.name }));
  }
  get chooseRecordType() {
    return this.isCreate && this.recordTypeOptions.length > 1;
  }
  changeRecordType(event) {
    if (
      !this.recordTypeOptions.some(
        (option) => option.value === event.detail.value
      )
    )
      return;
    this.selectedRecordType = event.detail.value;
    this.changes = {};
    this.defaults = undefined;
    this.layout = undefined;
    this.fieldErrors = {};
    this.error = "";
  }
  value(name) {
    if (Object.prototype.hasOwnProperty.call(this.changes, name))
      return this.changes[name];
    return (this.record || this.defaults)?.fields?.[name]?.value ?? null;
  }
  get sections() {
    return (this.layout?.sections || []).map((section, sectionIndex) => ({
      key: section.id || `section-${sectionIndex}`,
      heading: section.heading,
      rows: (section.layoutRows || []).map((row, rowIndex) => ({
        key: `row-${sectionIndex}-${rowIndex}`,
        fields: (row.layoutItems || []).flatMap((item) =>
          (item.layoutComponents || [])
            .filter((c) => c.componentType === "Field")
            .map((c) => {
              const metadata = this.info?.fields?.[c.apiName];
              const editable =
                metadata &&
                (this.recordId
                  ? metadata.updateable && item.editableForUpdate !== false
                  : metadata.createable && item.editableForNew !== false);
              return {
                name: c.apiName,
                label: metadata?.label,
                editable,
                visible: !!metadata,
                readOnly: !editable,
                isDate: DATE_FIELDS.includes(c.apiName),
                value: this.value(c.apiName),
                required: item.required || metadata?.required,
                error: this.fieldErrors[c.apiName]
              };
            })
            .filter((field) => field.visible)
        )
      }))
    }));
  }
  handleChange(event) {
    const name = event.target.fieldName || event.target.dataset.date;
    if (
      !this.sections.some((s) =>
        s.rows.some((r) => r.fields.some((f) => f.name === name && f.editable))
      )
    )
      return;
    this.changes = {
      ...this.changes,
      [name]: event.detail?.value ?? event.target.value ?? null
    };
    this.fieldErrors = { ...this.fieldErrors, [name]: "" };
    if (DATE_FIELDS.includes(name)) this.validateDates(false);
  }
  validateDates(focus) {
    const start = this.value("AvailabilityDate");
    const end = this.value("DiscontinuedDate");
    const invalid = !!(start && end && Date.parse(end) < Date.parse(start));
    const input = this.template.querySelector('[data-date="DiscontinuedDate"]');
    if (input) {
      input.setCustomValidity(invalid ? DATE_ERROR : "");
      input.reportValidity();
      if (invalid && focus) input.focus();
    }
    return !invalid;
  }
  interceptSubmit(event) {
    event.preventDefault();
    this.save();
  }
  async save() {
    if (!this.ready || this.disabled) return;
    const datesValid = this.validateDates(true);
    const controlsValid = [
      ...this.template.querySelectorAll(
        "lightning-input, lightning-input-field"
      )
    ].reduce((valid, input) => input.reportValidity() !== false && valid, true);
    if (!datesValid || !controlsValid) return;
    const fields = {};
    for (const section of this.sections)
      for (const row of section.rows)
        for (const field of row.fields) {
          if (
            field.editable &&
            (this.isCreate ||
              Object.prototype.hasOwnProperty.call(this.changes, field.name))
          ) {
            const value = this.value(field.name);
            if (
              value !== null ||
              field.required ||
              Object.prototype.hasOwnProperty.call(this.changes, field.name)
            )
              fields[field.name] = value;
          }
        }
    // Base fields own picklist dependencies and native input validation. Read their current
    // values on create, but never send untouched edit fields or inaccessible fields.
    for (const input of this.template.querySelectorAll(
      "lightning-input-field"
    )) {
      if (
        this.isCreate ||
        Object.prototype.hasOwnProperty.call(this.changes, input.fieldName)
      ) {
        if (
          (input.value !== undefined && input.value !== null) ||
          Object.prototype.hasOwnProperty.call(this.changes, input.fieldName)
        )
          fields[input.fieldName] = input.value ?? null;
      }
    }
    this.busy = true;
    this.error = "";
    this.fieldErrors = {};
    try {
      let saved;
      if (this.recordId) {
        if (!this.baselineModified) {
          const conflict = new Error(
            "Cannot verify record version. Close and reopen before saving."
          );
          conflict.status = 412;
          throw conflict;
        }
        saved = await updateRecord(
          { fields: { Id: this.recordId, ...fields } },
          { ifUnmodifiedSince: this.baselineModified }
        );
      } else {
        if (this.recordTypeId && this.recordTypeId !== "012000000000000AAA")
          fields.RecordTypeId = this.recordTypeId;
        saved = await createRecord({ apiName: "Product2", fields });
      }
      this.uncertain = true; // A completed write must never be repeated if navigation fails.
      if (this.recordId) {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        this.dispatchEvent(new CloseActionScreenEvent());
      }
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: {
          recordId: saved.id || this.recordId,
          objectApiName: "Product2",
          actionName: "view"
        }
      });
    } catch (error) {
      this.error = this.message(error);
      const fieldErrors = error.body?.output?.fieldErrors || {};
      this.fieldErrors = Object.fromEntries(
        Object.entries(fieldErrors).map(([name, errors]) => [
          name,
          errors.map((item) => item.message).join(" ")
        ])
      );
      // Only definitive client/validation rejections are retryable. Network/server failures
      // can have committed, so keep input but require reconciliation instead of retrying.
      if (!error.status || error.status >= 500 || error.status === 412) {
        this.uncertain = true;
        this.error +=
          " Save outcome or record version is unknown. Close and check the Product before trying again.";
      }
    } finally {
      this.busy = false;
    }
  }
  message(error) {
    const messages = [
      error.body?.message,
      ...(error.body?.output?.errors || []).map((item) => item.message),
      ...Object.values(error.body?.output?.fieldErrors || {}).flatMap(
        (errors) => errors.map((item) => item.message)
      ),
      error.message
    ].filter(Boolean);
    return (
      [...new Set(messages)].join(" ") ||
      "Unable to save Product. Review field errors."
    );
  }

  cancel() {
    if (this.busy) return;
    if (this.recordId) this.dispatchEvent(new CloseActionScreenEvent());
    else
      this[NavigationMixin.Navigate]({
        type: "standard__objectPage",
        attributes: { objectApiName: "Product2", actionName: "list" },
        state: { filterName: "AllProducts" }
      });
  }
}
