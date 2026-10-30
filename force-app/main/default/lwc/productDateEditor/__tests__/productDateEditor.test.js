import { createElement } from "lwc";
import ProductDateEditor from "c/productDateEditor";
import { getObjectInfo } from "lightning/uiObjectInfoApi";
import { getLayout } from "lightning/uiLayoutApi";
import {
  getRecord,
  getRecordCreateDefaults,
  createRecord,
  updateRecord
} from "lightning/uiRecordApi";
import { CurrentPageReference } from "lightning/navigation";
jest.mock(
  "lightning/actions",
  () => ({
    CloseActionScreenEvent: class extends CustomEvent {
      constructor() {
        super("lightning__actionsclosescreen");
      }
    }
  }),
  { virtual: true }
);
jest.mock(
  "lightning/uiLayoutApi",
  () => {
    const { createLdsTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { getLayout: createLdsTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock("@salesforce/i18n/timeZone", () => ({ default: "Asia/Taipei" }), {
  virtual: true
});
const flush = () =>
  Array.from({ length: 8 }).reduce(
    (chain) => chain.then(() => Promise.resolve()),
    Promise.resolve()
  );
const names = [
  "Name",
  "AvailabilityDate",
  "DiscontinuedDate",
  "Warranty_Months__c",
  "Model_Number__c"
];
const info = {
  apiName: "Product2",
  createable: true,
  updateable: true,
  defaultRecordTypeId: "012000000000000AAA",
  recordTypeInfos: {
    "012000000000000AAA": { available: true, name: "Master", master: true }
  },
  fields: Object.fromEntries(
    names.map((name) => [
      name,
      {
        apiName: name,
        label: name,
        createable: true,
        updateable: true,
        required: name === "Name"
      }
    ])
  )
};
const layout = {
  sections: [
    {
      id: "s1",
      heading: "Product",
      layoutRows: names.map((name) => ({
        layoutItems: [
          {
            editableForNew: true,
            editableForUpdate: true,
            required: name === "Name",
            layoutComponents: [{ componentType: "Field", apiName: name }]
          }
        ]
      }))
    }
  ]
};
async function mount(edit = false, permissions = {}) {
  const el = createElement("c-product-date-editor", { is: ProductDateEditor });
  document.body.appendChild(el);
  if (edit) el.recordId = "01t000000000001AAA";
  else CurrentPageReference.emit({ state: { c__mode: "create" } });
  getObjectInfo.emit({ ...info, ...permissions });
  await flush();
  if (edit)
    getRecord.emit({
      id: "01t000000000001AAA",
      apiName: "Product2",
      recordTypeId: "012000000000000AAA",
      fields: {
        Name: { value: "QA" },
        AvailabilityDate: { value: "2026-11-10T06:00:00.123Z" },
        DiscontinuedDate: { value: "2026-11-10T07:00:00.123Z" },
        LastModifiedDate: { value: "2026-10-28T01:00:00.000Z" }
      }
    });
  else
    getRecordCreateDefaults.emit({
      record: { fields: { Name: { value: null }, IsActive: { value: false } } }
    });
  getLayout.emit(layout);
  await flush();
  for (const input of el.shadowRoot.querySelectorAll(
    "lightning-input,lightning-input-field"
  )) {
    input.reportValidity = jest.fn(() => true);
    input.setCustomValidity = jest.fn();
    input.focus = jest.fn();
  }
  return el;
}
function date(el, name, value) {
  const input = el.shadowRoot.querySelector(`[data-date="${name}"]`);
  input.value = value;
  input.dispatchEvent(new CustomEvent("change", { detail: { value } }));
  return input;
}
function save(el) {
  el.shadowRoot.querySelector('[data-action="save"]').click();
}
afterEach(() => {
  document.body.replaceChildren();
  jest.clearAllMocks();
});
it.each(["2026-11-09T06:00:00.000Z", "2026-11-10T05:00:00.000Z"])(
  "rejects earlier full instant %s before a write",
  async (value) => {
    const el = await mount();
    date(el, "AvailabilityDate", "2026-11-10T06:00:00.000Z");
    const input = date(el, "DiscontinuedDate", value);
    save(el);
    await flush();
    expect(input.setCustomValidity).toHaveBeenLastCalledWith(
      "停售日期不可早於上市日期。"
    );
    expect(input.focus).toHaveBeenCalled();
    expect(createRecord).not.toHaveBeenCalled();
  }
);
it.each(["2026-11-10T06:00:00.000Z", "2026-11-10T07:00:00.000Z"])(
  "saves equal/later native instant %s",
  async (value) => {
    createRecord.mockResolvedValue({ id: "01t000000000001AAA" });
    const el = await mount();
    date(el, "AvailabilityDate", "2026-11-10T06:00:00.000Z");
    date(el, "DiscontinuedDate", value);
    save(el);
    await flush();
    expect(createRecord).toHaveBeenCalledWith(
      expect.objectContaining({
        apiName: "Product2",
        fields: expect.objectContaining({ DiscontinuedDate: value })
      })
    );
  }
);
it("clears error when either date is corrected and binds Salesforce timezone", async () => {
  const el = await mount();
  date(el, "AvailabilityDate", "2026-11-10T06:00:00Z");
  const end = date(el, "DiscontinuedDate", "2026-11-10T05:00:00Z");
  date(el, "AvailabilityDate", "2026-11-10T04:00:00Z");
  expect(end.setCustomValidity).toHaveBeenLastCalledWith("");
  expect(end.timezone).toBe("Asia/Taipei");
});
it("preserves untouched precision and uses optimistic concurrency", async () => {
  updateRecord.mockResolvedValue({ id: "01t000000000001AAA" });
  const el = await mount(true);
  date(el, "DiscontinuedDate", "2026-11-10T08:00:00.123Z");
  save(el);
  await flush();
  expect(updateRecord).toHaveBeenCalledWith(
    {
      fields: {
        Id: "01t000000000001AAA",
        DiscontinuedDate: "2026-11-10T08:00:00.123Z"
      }
    },
    { ifUnmodifiedSince: "2026-10-28T01:00:00.000Z" }
  );
});
it("allows blanks under native policy", async () => {
  createRecord.mockResolvedValue({ id: "01t000000000001AAA" });
  const el = await mount();
  date(el, "DiscontinuedDate", null);
  save(el);
  await flush();
  expect(createRecord).toHaveBeenCalled();
});
it("denies direct create and edit routes to catalog readers", async () => {
  const el = await mount(false, { createable: false, updateable: false });
  expect(el.shadowRoot.querySelector("lightning-input-field")).toBeNull();
  expect(el.shadowRoot.querySelector('[data-action="save"]')).toBeNull();
  expect(createRecord).not.toHaveBeenCalled();
});
it("retains layout fields but excludes inaccessible metadata fields", async () => {
  const el = await mount(false, {
    fields: {
      ...info.fields,
      Model_Number__c: { ...info.fields.Model_Number__c, createable: false }
    }
  });
  expect(
    [...el.shadowRoot.querySelectorAll("lightning-input-field")].map(
      (x) => x.fieldName
    )
  ).toEqual(["Name", "Warranty_Months__c"]);
});
it("retains field errors and permits correction after definitive validation failure", async () => {
  createRecord
    .mockRejectedValueOnce({
      status: 400,
      body: {
        output: {
          fieldErrors: {
            Warranty_Months__c: [{ message: "保固月數必須介於 0 到 60 個月。" }]
          },
          errors: []
        }
      }
    })
    .mockResolvedValueOnce({ id: "01t000000000001AAA" });
  const el = await mount();
  date(el, "AvailabilityDate", "2026-11-10T06:00:00Z");
  save(el);
  await flush();
  expect(el.shadowRoot.textContent).toContain(
    "保固月數必須介於 0 到 60 個月。"
  );
  expect(
    el.shadowRoot.querySelector('[data-date="AvailabilityDate"]').value
  ).toBe("2026-11-10T06:00:00Z");
  save(el);
  await flush();
  expect(createRecord).toHaveBeenCalledTimes(2);
});
it("prevents duplicate and uncertain creation retries", async () => {
  let reject;
  createRecord.mockImplementation(
    () =>
      new Promise((resolve, r) => {
        reject = r;
      })
  );
  const el = await mount();
  save(el);
  save(el);
  await flush();
  expect(createRecord).toHaveBeenCalledTimes(1);
  reject({ status: 0, body: { message: "Network disconnected" } });
  await flush();
  save(el);
  expect(createRecord).toHaveBeenCalledTimes(1);
  expect(el.shadowRoot.textContent).toContain("unknown");
});
it("cancel never writes", async () => {
  const el = await mount();
  el.shadowRoot.querySelector('[data-action="cancel"]').click();
  expect(createRecord).not.toHaveBeenCalled();
  expect(updateRecord).not.toHaveBeenCalled();
});
it("retains stale edit inputs without retry", async () => {
  updateRecord.mockRejectedValue({
    status: 412,
    body: { message: "Record changed" }
  });
  const el = await mount(true);
  date(el, "DiscontinuedDate", "2026-11-10T08:00:00Z");
  save(el);
  await flush();
  expect(updateRecord).toHaveBeenCalledTimes(1);
  expect(el.shadowRoot.textContent).toContain("Record changed");
  expect(
    el.shadowRoot.querySelector('[data-date="DiscontinuedDate"]').value
  ).toBe("2026-11-10T08:00:00Z");
});

// Aside regression 9397f83a: these native controls were absent from the original fixture.
const booleanNames = [
  "IsActive",
  "Dealer_Exclusive__c",
  "Requires_Installation__c"
];
async function mountNative(edit = false) {
  const el = await mount(edit);
  const extra = {
    ProductCode: { dataType: "String" },
    CurrencyIsoCode: { dataType: "Picklist", required: true },
    ...Object.fromEntries(
      booleanNames.map((name) => [
        name,
        { dataType: "Boolean", required: true }
      ])
    )
  };
  getObjectInfo.emit({
    ...info,
    fields: {
      ...info.fields,
      ...Object.fromEntries(
        Object.entries(extra).map(([name, props]) => [
          name,
          {
            apiName: name,
            label: name,
            createable: true,
            updateable: true,
            ...props
          }
        ])
      )
    }
  });
  if (!edit)
    getRecordCreateDefaults.emit({
      record: {
        fields: {
          Name: { value: null },
          CurrencyIsoCode: { value: "USD" },
          ...Object.fromEntries(
            booleanNames.map((name) => [name, { value: false }])
          )
        }
      }
    });
  getLayout.emit({
    sections: [
      {
        ...layout.sections[0],
        layoutRows: [
          ...layout.sections[0].layoutRows,
          ...Object.keys(extra).map((name) => ({
            layoutItems: [
              {
                required: name === "CurrencyIsoCode",
                editableForNew: true,
                editableForUpdate: true,
                layoutComponents: [{ componentType: "Field", apiName: name }]
              }
            ]
          }))
        ]
      }
    ]
  });
  await flush();
  for (const input of el.shadowRoot.querySelectorAll(
    "lightning-input,lightning-input-field"
  )) {
    // Mimic the documented base-component Boolean validation bug independently
    // of the explicit required property: false must not block the entire form.
    input.reportValidity = jest.fn(
      () => !booleanNames.includes(input.fieldName)
    );
    input.setCustomValidity = jest.fn();
    input.focus = jest.fn();
  }
  return el;
}
function native(el, name) {
  return [...el.shadowRoot.querySelectorAll("lightning-input-field")].find(
    (f) => f.fieldName === name
  );
}
it.each(["2026-11-10T06:00:00Z", "2026-11-10T07:00:00Z"])(
  "creates valid inactive Product at %s without forcing Boolean true",
  async (end) => {
    createRecord.mockResolvedValue({ id: "01t000000000001AAA" });
    const el = await mountNative();
    for (const name of booleanNames)
      expect(native(el, name).required).toBe(false);
    native(el, "Name").value = "QA sale datetimes";
    date(el, "AvailabilityDate", "2026-11-10T06:00:00Z");
    date(el, "DiscontinuedDate", end);
    await flush();
    save(el);
    await flush();
    expect(createRecord).toHaveBeenCalledTimes(1);
    expect(createRecord.mock.calls[0][0].fields).toEqual(
      expect.objectContaining({
        Name: "QA sale datetimes",
        CurrencyIsoCode: "USD",
        IsActive: false,
        Dealer_Exclusive__c: false,
        Requires_Installation__c: false,
        DiscontinuedDate: end
      })
    );
    for (const name of booleanNames)
      expect(native(el, name).reportValidity).not.toHaveBeenCalled();
  }
);
it("keeps native currency, Name and Code values across change and date-error rerenders", async () => {
  const el = await mountNative();
  async function changeNative(name, value, detail) {
    const input = native(el, name);
    input.value = value;
    input.dispatchEvent(new CustomEvent("change", { detail }));
    await flush();
    expect(input.value).toBe(value);
  }
  await changeNative("CurrencyIsoCode", "USD", { value: ["USD"] });
  await changeNative("Name", "QA retained name", {
    value: ["not a text value"]
  });
  await changeNative("ProductCode", "QA-code", {});
  date(el, "AvailabilityDate", "2026-11-10T06:00:00Z");
  date(el, "DiscontinuedDate", "2026-11-10T05:00:00Z");
  save(el);
  await flush();
  expect(createRecord).not.toHaveBeenCalled();
  expect(native(el, "CurrencyIsoCode").value).toBe("USD");
  expect(native(el, "Name").value).toBe("QA retained name");
  expect(native(el, "ProductCode").value).toBe("QA-code");
});
it("preserves required text and currency validation rather than bypassing all native fields", async () => {
  const el = await mountNative();
  expect(native(el, "Name").required).toBe(true);
  expect(native(el, "CurrencyIsoCode").required).toBe(true);
  native(el, "Name").reportValidity = jest.fn(() => false);
  save(el);
  await flush();
  expect(native(el, "Name").reportValidity).toHaveBeenCalled();
  expect(native(el, "CurrencyIsoCode").reportValidity).toHaveBeenCalled();
  expect(createRecord).not.toHaveBeenCalled();
});
it("submits false Boolean changes on edit without string coercion or unrelated defaults", async () => {
  updateRecord.mockResolvedValue({ id: "01t000000000001AAA" });
  const el = await mountNative(true);
  const input = native(el, "IsActive");
  input.value = false;
  input.dispatchEvent(
    new CustomEvent("change", { detail: { checked: false } })
  );
  await flush();
  save(el);
  await flush();
  expect(updateRecord).toHaveBeenCalledWith(
    { fields: { Id: "01t000000000001AAA", IsActive: false } },
    { ifUnmodifiedSince: "2026-10-28T01:00:00.000Z" }
  );
});
it("retains native entries and false defaults through server rejection then creates only once successfully", async () => {
  createRecord
    .mockRejectedValueOnce({
      status: 400,
      body: {
        output: {
          fieldErrors: {
            Warranty_Months__c: [{ message: "保固月數必須介於 0 到 60 個月。" }]
          }
        }
      }
    })
    .mockResolvedValueOnce({ id: "01t000000000001AAA" });
  const el = await mountNative();
  native(el, "Name").value = "QA recovery";
  native(el, "ProductCode").value = "recovery-code";
  native(el, "Warranty_Months__c").value = 61;
  date(el, "AvailabilityDate", "2026-11-10T06:00:00Z");
  date(el, "DiscontinuedDate", "2026-11-10T07:00:00Z");
  save(el);
  await flush();
  expect(el.shadowRoot.textContent).toContain(
    "保固月數必須介於 0 到 60 個月。"
  );
  expect(native(el, "Name").value).toBe("QA recovery");
  expect(native(el, "ProductCode").value).toBe("recovery-code");
  expect(native(el, "CurrencyIsoCode").value).toBe("USD");
  native(el, "Warranty_Months__c").value = 12;
  native(el, "Warranty_Months__c").dispatchEvent(new CustomEvent("change"));
  await flush();
  save(el);
  await flush();
  save(el);
  expect(createRecord).toHaveBeenCalledTimes(2);
  expect(createRecord.mock.calls[1][0].fields).toEqual(
    expect.objectContaining({
      Name: "QA recovery",
      ProductCode: "recovery-code",
      CurrencyIsoCode: "USD",
      IsActive: false,
      Dealer_Exclusive__c: false,
      Requires_Installation__c: false,
      Warranty_Months__c: 12,
      DiscontinuedDate: "2026-11-10T07:00:00Z"
    })
  );
});
it("normalizes native scalar picklist arrays only in the write payload", async () => {
  createRecord.mockResolvedValue({ id: "01t000000000001AAA" });
  const el = await mountNative();
  native(el, "Name").value = "QA scalar";
  native(el, "CurrencyIsoCode").value = ["USD"];
  native(el, "CurrencyIsoCode").dispatchEvent(
    new CustomEvent("change", { detail: { value: ["USD"] } })
  );
  await flush();
  save(el);
  await flush();
  expect(createRecord.mock.calls[0][0].fields.CurrencyIsoCode).toBe("USD");
});
it("still rejects an empty required currency with unchecked Booleans present", async () => {
  const el = await mountNative();
  native(el, "CurrencyIsoCode").value = null;
  native(el, "CurrencyIsoCode").reportValidity = jest.fn(() => false);
  save(el);
  await flush();
  expect(createRecord).not.toHaveBeenCalled();
});
