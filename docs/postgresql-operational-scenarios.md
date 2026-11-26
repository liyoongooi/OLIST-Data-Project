# PostgreSQL operational scenarios

These two read-only queries turn the Olist operational tables into order-level work queues. Open the applicable SQL file in pgAdmin's Query Tool connected to `olist_portfolio`, then execute it. Adjust the dates and assumptions in the opening `parameters` CTE to explore another period.

The default examples use orders purchased from **1 through 31 July 2018**. The queries were verified in pgAdmin against the full `olist_source` schema. The cohort recorded **R$1,066,540.75 in customer payments**, summed across all its orders, including orders outside both queues. The source has no payment timestamps, so this is the recorded payment total for July purchases, regardless of when the payments occurred. Summary values repeat on each returned order for reference. Read them once. If the queue is empty, the query returns no rows.

## 1. Fulfillment exception queue

**Business question.** At the start of 1 September 2018, which July orders were past their estimated delivery date and lacked a valid recorded delivery by the cutoff? Who should investigate?

[Run the fulfillment exception query](../sql/postgresql/fulfillment_exception_queue.sql).

| Verified result | Operational response |
|---|---|
| 81 orders with a recorded carrier handoff | Check tracking with the carrier and give customer support a status update. |
| 54 orders with seller details and no recorded handoff by the cutoff | Ask the listed sellers to confirm dispatch and provide tracking evidence. |
| Oldest case was 44 days past its estimated date | Start with the oldest cases and agree on the next action with support. |

Orders with missing items or inconsistent timestamps can be routed for record checks before contacting a seller or carrier. The query uses CTEs, date arithmetic, conditional routing, and `string_agg(DISTINCT ...)` to list all sellers while keeping one row per order. Later handoff and delivery events are evaluated relative to the cutoff. The snapshot lacks a complete status history, so operations would confirm whether a case was still active before escalation.

**What the company gains.** Without a queue, an overdue order can wait until the customer complains. By then, a tracking issue that could have been resolved earlier may require extra support contacts, a replacement, or a refund. The queue identifies who can investigate each case while there is still time to act.

**Illustrative financial impact.** If earlier intervention prevented a costly outcome in **10% of the 135 seller or carrier follow-ups**, at **R$60 per prevented outcome**, the estimated gross avoided cost would be **R$810.00**, or **0.0759%** of the cohort's recorded customer payments. This is a one-time estimate for the queue at the chosen cutoff. Both inputs are assumptions, and the dataset does not measure realized savings or staff costs.

## 2. Payment reconciliation queue

**Business question.** Which July orders have missing item or payment records, or a difference greater than R$0.01 between recorded payments and item prices plus freight?

[Run the payment reconciliation query](../sql/postgresql/payment_reconciliation_queue.sql).

| Verified result | Operational response |
|---|---|
| 19 orders with missing item records | Check the order system and the ingestion records for missing line items. Confirm the order context before making any financial adjustment. |
| 9 orders above expected by R$96.67 in total | Compare processor records, adjustments, and order details to determine whether any customer correction is needed. |
| 2 orders below expected by R$0.04 in total | Confirm the discrepancy with the processor. Handle immaterial differences under the company's reconciliation policy. |

The query aggregates items and payments independently before joining each total to the order. This prevents an order with multiple items and payments from multiplying both totals. Left joins keep orders with missing records visible. Missing amounts remain null, and the signed difference is recorded payments minus expected charges. The order ID, payment types, and payment-record count support the follow-up.

**What the company gains.** Without reconciliation, missing records and possible customer overcharges can stay unresolved until month-end. Running the queue during the month gives finance a list of specific cases to clear before close and a way to separate record-completeness issues from monetary discrepancies. In this cohort, **customer corrections and missing records are the stronger business case** because the observed underpayment gaps are only a few cents.

**Illustrative financial impact.** If **20% of the R$0.04 below-expected total** were confirmed as recoverable, the estimated recovery would round to **R$0.01**, or **less than 0.0001%** of recorded customer payments. The SQL percentage displays `0.0000` at four decimal places. The 20% share is an assumption. Above-expected amounts and missing records are excluded from the recovery estimate, and the raw discrepancies do not establish a financial loss.
