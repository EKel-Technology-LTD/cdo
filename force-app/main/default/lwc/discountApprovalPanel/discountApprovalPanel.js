import { LightningElement, api, wire } from 'lwc';
import getPanel from '@salesforce/apex/DiscountApprovalService.getPanel';
import decide from '@salesforce/apex/DiscountApprovalService.decide';
import resubmit from '@salesforce/apex/DiscountApprovalService.resubmit';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
export default class DiscountApprovalPanel extends LightningElement {
    @api recordId;
    panel;
    error;
    comment = '';
    busy = false;
    wiredResult;
    @wire(getPanel, { opportunityId: '$recordId' })
    wiredPanel(result) {
        this.wiredResult = result;
        if (result.data) { this.panel = result.data; this.error = undefined; }
        else if (result.error) { this.panel = undefined; this.error = this.message(result.error); }
    }
    get history() {
        return (this.panel?.history || []).map(cycle => ({ ...cycle, decidedBy: cycle.Decided_By__r?.Name || '' }));
    }
    handleComment(event) { this.comment = event.target.value; }
    approve() { this.saveDecision('Approved'); }
    reject() { this.saveDecision('Rejected'); }
    async saveDecision(outcome) {
        const input = this.template.querySelector('lightning-textarea');
        input.setCustomValidity(this.comment.trim() ? '' : 'Enter a comment to approve or reject.');
        if (!input.reportValidity() || this.busy) return;
        await this.perform(() => decide({ approvalId: this.panel.approvalId, outcome, comment: this.comment }));
    }
    async handleResubmit() { await this.perform(() => resubmit({ opportunityId: this.recordId })); }
    async perform(action) {
        if (this.busy) return;
        this.busy = true;
        try {
            await action();
            this.comment = '';
            await Promise.all([refreshApex(this.wiredResult), notifyRecordUpdateAvailable([{ recordId: this.recordId }])]);
            this.dispatchEvent(new ShowToastEvent({ title: 'Discount approval updated', variant: 'success' }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Discount approval', message: this.message(error), variant: 'error' }));
        } finally { this.busy = false; }
    }
    message(error) { return error?.body?.message || error?.message || 'Unable to load discount approval.'; }
}
