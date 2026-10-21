import { createElement } from 'lwc';
import DiscountApprovalPanel from 'c/discountApprovalPanel';
import getPanel from '@salesforce/apex/DiscountApprovalService.getPanel';
import decide from '@salesforce/apex/DiscountApprovalService.decide';
import resubmit from '@salesforce/apex/DiscountApprovalService.resubmit';
jest.mock('@salesforce/apex/DiscountApprovalService.getPanel', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/DiscountApprovalService.decide', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/DiscountApprovalService.resubmit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn().mockResolvedValue() }), { virtual: true });
const flush = () => Promise.resolve();
function mount(data) {
    const element = createElement('c-discount-approval-panel', { is: DiscountApprovalPanel });
    element.recordId = '006000000000001AAA';
    document.body.appendChild(element);
    getPanel.emit({ opportunity: {}, history: [], approvalId: 'a00000000000001AAA', ...data });
    return element;
}
afterEach(() => { while (document.body.firstChild) document.body.removeChild(document.body.firstChild); jest.clearAllMocks(); });
it('renders rep fields without decision controls', async () => {
    const element = mount({ canDecide: false, canResubmit: false }); await flush();
    expect(element.shadowRoot.querySelectorAll('lightning-output-field')).toHaveLength(6);
    expect(element.shadowRoot.querySelectorAll('lightning-button')).toHaveLength(0);
});
it('requires comment and does not call Apex for blank input', async () => {
    const element = mount({ canDecide: true }); await flush();
    const input = element.shadowRoot.querySelector('lightning-textarea');
    input.reportValidity = jest.fn().mockReturnValue(false); input.setCustomValidity = jest.fn();
    element.shadowRoot.querySelector('lightning-button').click(); await flush();
    expect(input.required).toBe(true);
    expect(input.setCustomValidity).toHaveBeenCalledWith('Enter a comment to approve or reject.');
    expect(decide).not.toHaveBeenCalled();
});
it('submits an approval with a comment', async () => {
    decide.mockResolvedValue();
    const element = mount({ canDecide: true }); await flush();
    const input = element.shadowRoot.querySelector('lightning-textarea');
    input.reportValidity = jest.fn().mockReturnValue(true); input.setCustomValidity = jest.fn();
    input.value = 'Margin accepted'; input.dispatchEvent(new CustomEvent('change'));
    element.shadowRoot.querySelector('lightning-button').click(); await flush();
    expect(decide).toHaveBeenCalledWith({ approvalId: 'a00000000000001AAA', outcome: 'Approved', comment: 'Margin accepted' });
});
it('submits rejection', async () => {
    decide.mockResolvedValue();const element = mount({ canDecide: true });await flush();
    const input=element.shadowRoot.querySelector('lightning-textarea');
    input.reportValidity=jest.fn().mockReturnValue(true);input.setCustomValidity=jest.fn();input.value='Margin below floor';input.dispatchEvent(new CustomEvent('change'));
    element.shadowRoot.querySelectorAll('lightning-button')[1].click();await flush();
    expect(decide).toHaveBeenCalledWith(expect.objectContaining({ outcome:'Rejected',comment:'Margin below floor' }));
});
it('shows history and owner resubmit after rejection', async () => {
    resubmit.mockResolvedValue();const element = mount({ canDecide: false, canResubmit: true, history: [{ Id:'a00000000000001AAA',Name:'DA-000001',Status__c:'Rejected',Route__c:'Deal Desk',Decided_By__r:{Name:'Dana Analyst'},Decision_Comment__c:'Margin below floor' }] });await flush();
    expect(element.shadowRoot.textContent).toContain('Dana Analyst');
    expect(element.shadowRoot.querySelector('lightning-formatted-text').value).toBe('Margin below floor');
    const button=element.shadowRoot.querySelector('lightning-button');expect(button.label).toBe('Resubmit');button.click();await flush();
    expect(resubmit).toHaveBeenCalledWith({ opportunityId:'006000000000001AAA' });
});
it('renders load error without decision controls',async()=>{
    const element=mount({});getPanel.error({message:'Access denied'});await flush();
    expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Access denied');
    expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
});
it('shows decision failure in an error toast',async()=>{
    decide.mockRejectedValue({body:{message:'Decision no longer current'}});const element=mount({canDecide:true});await flush();
    const listener=jest.fn();element.addEventListener('lightning__showtoast',listener);
    const input=element.shadowRoot.querySelector('lightning-textarea');input.reportValidity=jest.fn().mockReturnValue(true);input.setCustomValidity=jest.fn();input.value='OK';input.dispatchEvent(new CustomEvent('change'));
    element.shadowRoot.querySelector('lightning-button').click();await flush();
    expect(listener).toHaveBeenCalled();expect(listener.mock.calls[0][0].detail.variant).toBe('error');
});
