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
