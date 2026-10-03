# E-commerce Cohort Retention & RFM Analysis (SQL)

Do Olist customers come back, and which customers matter most? This project answers that in SQL,
using the [Olist Brazilian E-commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
(99,441 orders, Sep 2016 to Oct 2018, 9 tables).

## Headline results

| Metric | Value |
|---|---|
| Delivered orders analysed | 96,477 |
| Unique customers (`customer_unique_id`) | 93,357 |
| Revenue (BRL) | 15.42M |
| **Repeat purchase rate** | **3.0%** (2.16% counting only returns on a different day) |
| Average month-1 retention | 0.48% |
| Revenue from top 20% of customers | 53.5% |
| Avg review score: on time vs late | 4.29 vs 2.27 |

![Cohort retention heatmap](charts/1_cohort_retention_heatmap.png)
![RFM segments](charts/3_rfm_segments.png)
![Review score by delivery timing](charts/4_review_score_by_delivery.png)

## Findings

1. **Almost nobody comes back.** 97% of customers buy once. Of the 2,801 repeat customers, 30%
   placed their "second" order the same day as the first, which is one basket split into several
   orders rather than a return visit. Excluding those, the true repeat rate is 2.16%.
2. **Retention is flat across cohorts.** No cohort exceeds 0.7% in any month after joining, and
   the 2018 cohorts look like the 2017 ones. Low retention is structural, not a recent decline.
3. **Revenue comes from large single baskets.** Promising (recent, high spend) and At Risk
   (older, high spend) customers are 30% of the base and 55% of revenue, all with one order each.
   True repeat buyers (Champions + Loyal) are 3% of customers and 5.6% of revenue.
4. **Revenue is concentrated, but not 80/20.** Top 1% = 10.3%, top 20% = 53.5%, top 50% = 80.8%.
5. **Late deliveries hurt.** 6.7% of orders arrive late. They average 2.27 stars against 4.29, and
   62% get 1 or 2 stars. Customers whose first order was late repeat at 2.55% vs 3.03%.

## Files

| File | What it is |
|---|---|
| `queries.sql` | Every query, commented and named by step. This is the main deliverable. |
| `analysis.ipynb` | Runs the queries from `queries.sql` by name with `pandas.read_sql` and draws the charts |
| `charts/` | Exported PNGs |
| `load_data.py` | Loads the 9 CSVs into `olist.db` (same as DB Browser's Import Table from CSV) |

## How to run

1. Download the dataset from Kaggle and unzip the CSVs into `data/`.
2. `python load_data.py` builds `olist.db`.
3. Open `queries.sql` in DB Browser for SQLite and run statements one at a time, or run the whole
   file with `sqlite3 olist.db < queries.sql` (about 10 seconds).
4. Run `analysis.ipynb` to rebuild the charts.

Needs SQLite 3.25+ for window functions, and Python with pandas and matplotlib.

## Data decisions

- **`customer_unique_id`, not `customer_id`.** Olist issues a new `customer_id` for every order.
  Grouping by it gives a repeat rate of exactly 0% (`repeat_rate_wrong_id` proves it).
- **Delivered orders only** (97% of orders). Canceled or unavailable orders are not revenue.
- **Payments are summed per order before joining.** 3% of orders have several payment rows
  (vouchers plus card, for example), and a direct join would double-count them.
- **Recency is measured from the last purchase in the data** (2018-08-29), not from today.
- **Frequency is not scored with `NTILE(5)`.** With 97% one-time buyers, NTILE puts identical
  customers into scores 1 to 4 arbitrarily (`ntile_frequency_check` shows every bucket from 1 to
  4 holds only 1-order customers). F is the order count capped at 5 instead.
- **The heatmap drops the 2016 cohorts** (under 300 customers, with a gap in Nov 2016) and blanks
  out cells the data cannot reach yet.

## Interview prep

**What is a cohort, and why not just look at overall retention?**
A cohort is a group of customers who share a start point, here the month of their first order.
Overall retention mixes customers of different ages: a business that is growing fast is full of
new customers who haven't had time to return, which drags the overall figure down even if
behaviour is unchanged. Cohorts compare like with like, so you can tell whether customers who
joined in 2018 behave differently from those who joined in 2017. Here they don't, which shows
the problem is structural.

**Why `customer_unique_id` instead of `customer_id`?**
`customer_id` is created per order, so each one has exactly one order. Using it, every customer
looks like a one-time buyer and the repeat rate is 0%. `customer_unique_id` is the person; it
shows 96,096 people behind 99,441 customer ids.

**Explain a window function you used.**
For revenue concentration, `SUM(spend) OVER (ORDER BY spend DESC ROWS BETWEEN UNBOUNDED PRECEDING
AND CURRENT ROW)` gives a running total of revenue as you go down the customer list from the
biggest spender. Unlike `GROUP BY`, a window function keeps every row, so each customer carries
their rank (`ROW_NUMBER()`), the running total, and the grand total (`SUM(spend) OVER ()`) side by
side. Dividing running by grand total at the 20% rank gives 53.5%. I also used `LAG()` to find
the gap between a customer's first and second order, and `NTILE(5)` for the R and M scores.

**With a 3% repeat rate, what would you recommend?**
1. *Accept the model and optimise acquisition.* Olist is a marketplace where most purchases are
   one-off (furniture, appliances, gifts). Value is in big first baskets, so spend on acquisition
   and first-order conversion, judged against first-order margin rather than a lifetime value that
   assumes repeats.
2. *Fix late deliveries first.* It is the clearest controllable driver of bad reviews (4.29 to
   2.27 stars) and lowers repeat rate. Set more conservative delivery estimates and flag sellers
   with high late rates.
3. *Run a targeted win-back test* on Promising and At Risk customers (30% of customers, 55% of
   revenue), for example a second-purchase voucher in the 30 to 90 days after the first order, with a
   holdout group to measure whether it actually moves the repeat rate.
4. *Next analysis:* join `order_items` and `products` to see which categories repeat buyers come
   from, and focus retention spending on those categories.
