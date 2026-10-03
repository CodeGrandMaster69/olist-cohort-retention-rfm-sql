/* =====================================================================
   E-commerce Cohort Retention & RFM Analysis — Olist (Brazil, 2016-2018)
   ---------------------------------------------------------------------
   Business question:
     1. What share of customers make a second purchase?
     2. How does retention change by the month a customer joined?
     3. Which customer segments drive revenue?

   Engine: SQLite 3.25+ (window functions). Runs as-is in DB Browser for
   SQLite; load the tables first with load_data.py or File -> Import.

   Each query starts with a "-- name:" line. The notebook uses these to
   run the queries, so the SQL lives in one place.

   KEY TRAP: customers.customer_id is a NEW id for every order. The same
   person keeps the same customer_unique_id. Every customer-level query
   below groups by customer_unique_id; using customer_id would make every
   customer look like a one-time buyer.
   ===================================================================== */


/* =====================================================================
   STEP 2 — EXPLORE
   ===================================================================== */

-- name: table_row_counts
-- Row count per table: a quick sanity check that every CSV loaded fully.
SELECT 'orders'      AS table_name, COUNT(*) AS row_count FROM orders      UNION ALL
SELECT 'customers',                 COUNT(*)              FROM customers   UNION ALL
SELECT 'order_items',               COUNT(*)              FROM order_items UNION ALL
SELECT 'payments',                  COUNT(*)              FROM payments    UNION ALL
SELECT 'reviews',                   COUNT(*)              FROM reviews     UNION ALL
SELECT 'products',                  COUNT(*)              FROM products    UNION ALL
SELECT 'sellers',                   COUNT(*)              FROM sellers     UNION ALL
SELECT 'geolocation',               COUNT(*)              FROM geolocation UNION ALL
SELECT 'category_translation',      COUNT(*)              FROM category_translation;

-- name: order_status_mix
-- 97% of orders are 'delivered'. Revenue work uses delivered orders only,
-- because canceled / unavailable orders never turned into real sales.
SELECT
    order_status,
    COUNT(*)                                           AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders
FROM orders
GROUP BY order_status
ORDER BY orders DESC;

-- name: customer_id_trap
-- Proof of the key trap: 99,441 customer_ids but only 96,096 real people.
SELECT
    COUNT(DISTINCT customer_id)        AS distinct_customer_id,
    COUNT(DISTINCT customer_unique_id) AS distinct_customer_unique_id
FROM customers;

-- name: date_range
-- Delivered orders stop in Aug 2018; later rows are still in transit or canceled.
SELECT
    MIN(order_purchase_timestamp) AS first_purchase,
    MAX(order_purchase_timestamp) AS last_purchase
FROM orders
WHERE order_status = 'delivered';

-- name: payment_rows_per_order
-- Some orders are paid in several parts (e.g. voucher + card), so payments
-- holds more than one row per order. Joining it straight onto orders would
-- duplicate orders. Payments must be summed per order first (see the view).
SELECT
    payment_rows,
    COUNT(*) AS orders
FROM (
    SELECT order_id, COUNT(*) AS payment_rows
    FROM payments
    GROUP BY order_id
)
GROUP BY payment_rows
ORDER BY payment_rows;


/* =====================================================================
   STEP 3 — CLEAN ORDERS VIEW
   One row per delivered order: who bought it (customer_unique_id),
   when, and how much they paid.
   ===================================================================== */

DROP VIEW IF EXISTS clean_orders;

CREATE VIEW clean_orders AS
WITH order_payments AS (            -- collapse split payments to one row per order
    SELECT
        order_id,
        SUM(payment_value) AS order_value
    FROM payments
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_unique_id,
    o.order_purchase_timestamp                    AS purchase_ts,
    DATE(o.order_purchase_timestamp)              AS purchase_date,
    STRFTIME('%Y-%m', o.order_purchase_timestamp) AS purchase_month,
    p.order_value
FROM orders o
JOIN customers c       ON c.customer_id = o.customer_id
JOIN order_payments p  ON p.order_id    = o.order_id   -- drops 1 delivered order with no payment record
WHERE o.order_status = 'delivered';

-- name: clean_orders_summary
-- Sanity check on the view: order count, people, total revenue (BRL).
SELECT
    COUNT(*)                           AS orders,
    COUNT(DISTINCT customer_unique_id) AS customers,
    ROUND(SUM(order_value), 2)         AS revenue,
    ROUND(AVG(order_value), 2)         AS avg_order_value
FROM clean_orders;


/* =====================================================================
   STEP 4 — FIRST PURCHASE MONTH (the customer's cohort)
   ===================================================================== */

-- name: cohort_sizes
-- New customers acquired per month. The cohort is the month of a
-- customer's first delivered order.
WITH first_purchase AS (
    SELECT
        customer_unique_id,
        MIN(purchase_ts) AS first_purchase_ts
    FROM clean_orders
    GROUP BY customer_unique_id
)
SELECT
    STRFTIME('%Y-%m', first_purchase_ts) AS cohort_month,
    COUNT(*)                             AS new_customers
FROM first_purchase
GROUP BY cohort_month
ORDER BY cohort_month;


/* =====================================================================
   STEP 5 — COHORT RETENTION TABLE
   For each cohort and each "months since first order" (month 0, 1, 2...),
   the % of the cohort that placed an order in that month.
   ===================================================================== */

-- name: cohort_retention
WITH first_purchase AS (
    SELECT
        customer_unique_id,
        MIN(purchase_month) AS cohort_month
    FROM clean_orders
    GROUP BY customer_unique_id
),
orders_with_month_number AS (       -- tag every order with its months-since-first-order
    SELECT
        o.customer_unique_id,
        f.cohort_month,
        (CAST(SUBSTR(o.purchase_month, 1, 4) AS INTEGER) * 12 + CAST(SUBSTR(o.purchase_month, 6, 2) AS INTEGER))
      - (CAST(SUBSTR(f.cohort_month,   1, 4) AS INTEGER) * 12 + CAST(SUBSTR(f.cohort_month,   6, 2) AS INTEGER))
            AS month_number
    FROM clean_orders o
    JOIN first_purchase f ON f.customer_unique_id = o.customer_unique_id
),
active_customers AS (               -- distinct buyers per cohort per month number
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT customer_unique_id) AS active_customers
    FROM orders_with_month_number
    GROUP BY cohort_month, month_number
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS cohort_customers
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    a.cohort_month,
    s.cohort_customers,
    a.month_number,
    a.active_customers,
    ROUND(100.0 * a.active_customers / s.cohort_customers, 2) AS retention_pct
FROM active_customers a
JOIN cohort_size s ON s.cohort_month = a.cohort_month
ORDER BY a.cohort_month, a.month_number;

-- name: retention_by_month_number
-- Overall retention curve: all cohorts pooled, weighted by cohort size.
-- A cohort only counts toward month N if the data covers its month N
-- (e.g. the Jul-2018 cohort cannot have a month-3 value yet).
WITH first_purchase AS (
    SELECT customer_unique_id, MIN(purchase_month) AS cohort_month
    FROM clean_orders
    GROUP BY customer_unique_id
),
month_index AS (                    -- convert 'YYYY-MM' to a running month count
    SELECT
        customer_unique_id,
        CAST(SUBSTR(purchase_month, 1, 4) AS INTEGER) * 12
      + CAST(SUBSTR(purchase_month, 6, 2) AS INTEGER) AS order_month_idx
    FROM clean_orders
),
cohort_index AS (
    SELECT
        customer_unique_id,
        cohort_month,
        CAST(SUBSTR(cohort_month, 1, 4) AS INTEGER) * 12
      + CAST(SUBSTR(cohort_month, 6, 2) AS INTEGER) AS cohort_month_idx
    FROM first_purchase
),
last_month AS (
    SELECT MAX(order_month_idx) AS last_month_idx FROM month_index
),
cohort_size AS (                    -- size and months of history per cohort
    SELECT
        ci.cohort_month,
        COUNT(*)                             AS cohort_customers,
        lm.last_month_idx - ci.cohort_month_idx AS months_observed
    FROM cohort_index ci
    CROSS JOIN last_month lm
    GROUP BY ci.cohort_month
),
active_customers AS (
    SELECT
        ci.cohort_month,
        mi.order_month_idx - ci.cohort_month_idx AS month_number,
        COUNT(DISTINCT mi.customer_unique_id)    AS active_customers
    FROM month_index mi
    JOIN cohort_index ci ON ci.customer_unique_id = mi.customer_unique_id
    GROUP BY ci.cohort_month, month_number
),
month_numbers(month_number) AS (    -- recursive CTE: generates 1..12
    SELECT 1
    UNION ALL
    SELECT month_number + 1 FROM month_numbers WHERE month_number < 12
)
SELECT
    m.month_number,
    SUM(COALESCE(a.active_customers, 0))                                         AS active_customers,
    SUM(s.cohort_customers)                                                      AS eligible_customers,
    ROUND(100.0 * SUM(COALESCE(a.active_customers, 0)) / SUM(s.cohort_customers), 3) AS retention_pct
FROM month_numbers m
JOIN cohort_size s
  ON s.months_observed >= m.month_number
LEFT JOIN active_customers a
  ON a.cohort_month = s.cohort_month
 AND a.month_number = m.month_number
GROUP BY m.month_number
ORDER BY m.month_number;


/* =====================================================================
   STEP 6 — REPEAT PURCHASE RATE
   ===================================================================== */

-- name: repeat_rate
-- Share of customers with 2+ delivered orders. The stricter version only
-- counts purchases on 2+ different days: about 30% of "second orders" are
-- placed the same day as the first (one basket split into several orders),
-- which is not a real return visit.
WITH orders_per_customer AS (
    SELECT
        customer_unique_id,
        COUNT(*)                      AS orders,
        COUNT(DISTINCT purchase_date) AS purchase_days
    FROM clean_orders
    GROUP BY customer_unique_id
)
SELECT
    COUNT(*)                                                         AS customers,
    SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END)                     AS repeat_customers,
    ROUND(100.0 * SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END)
                / COUNT(*), 2)                                       AS repeat_rate_pct,
    SUM(CASE WHEN purchase_days >= 2 THEN 1 ELSE 0 END)              AS returned_another_day,
    ROUND(100.0 * SUM(CASE WHEN purchase_days >= 2 THEN 1 ELSE 0 END)
                / COUNT(*), 2)                                       AS true_repeat_rate_pct
FROM orders_per_customer;

-- name: repeat_rate_wrong_id
-- The same calculation with the WRONG key (customer_id). The repeat rate
-- drops to exactly 0%, because every customer_id has one order by design.
WITH orders_per_customer_id AS (
    SELECT o.customer_id, COUNT(*) AS orders
    FROM orders o
    WHERE o.order_status = 'delivered'
    GROUP BY o.customer_id
)
SELECT
    COUNT(*)                                                   AS customer_ids,
    ROUND(100.0 * SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END)
                / COUNT(*), 2)                                 AS repeat_rate_pct
FROM orders_per_customer_id;

-- name: order_count_distribution
-- How many customers placed 1, 2, 3... orders, and their share of revenue.
WITH customer_totals AS (
    SELECT customer_unique_id, COUNT(*) AS orders, SUM(order_value) AS spend
    FROM clean_orders
    GROUP BY customer_unique_id
)
SELECT
    CASE WHEN orders >= 4 THEN '4+' ELSE CAST(orders AS TEXT) END   AS orders_placed,
    COUNT(*)                                                        AS customers,
    ROUND(100.0 * COUNT(*)   / SUM(COUNT(*))   OVER (), 2)          AS pct_customers,
    ROUND(100.0 * SUM(spend) / SUM(SUM(spend)) OVER (), 2)          AS pct_revenue
FROM customer_totals
GROUP BY orders_placed
ORDER BY orders_placed;

-- name: days_to_second_order
-- For repeat buyers: how long until the second order? LAG() looks back
-- one row within each customer's order history.
WITH ordered_purchases AS (
    SELECT
        customer_unique_id,
        purchase_ts,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS order_seq,
        LAG(purchase_ts) OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS prev_purchase_ts
    FROM clean_orders
),
second_orders AS (
    SELECT JULIANDAY(purchase_ts) - JULIANDAY(prev_purchase_ts) AS days_gap
    FROM ordered_purchases
    WHERE order_seq = 2
)
SELECT
    CASE
        WHEN days_gap <   1 THEN '0 same day'
        WHEN days_gap <= 30 THEN '1 within 30 days'
        WHEN days_gap <= 90 THEN '2 31-90 days'
        WHEN days_gap <= 180 THEN '3 91-180 days'
        ELSE                    '4 over 180 days'
    END                                                   AS gap_bucket,
    COUNT(*)                                              AS repeat_customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct
FROM second_orders
GROUP BY gap_bucket
ORDER BY gap_bucket;


/* =====================================================================
   STEP 7 — RFM SCORES
   Recency   = days from last order to the dataset's last purchase date
   Frequency = number of delivered orders
   Monetary  = total amount paid
   ===================================================================== */

DROP VIEW IF EXISTS customer_rfm;

CREATE VIEW customer_rfm AS
WITH snapshot AS (                  -- "today" = last purchase date in the data
    SELECT MAX(purchase_ts) AS snapshot_ts FROM clean_orders
),
customer_metrics AS (
    SELECT
        o.customer_unique_id,
        CAST(JULIANDAY(s.snapshot_ts) - JULIANDAY(MAX(o.purchase_ts)) AS INTEGER) AS recency_days,
        COUNT(*)                                                                  AS frequency,
        ROUND(SUM(o.order_value), 2)                                              AS monetary
    FROM clean_orders o
    CROSS JOIN snapshot s
    GROUP BY o.customer_unique_id
)
SELECT
    customer_unique_id,
    recency_days,
    frequency,
    monetary,
    -- R: most recent customers get 5, so sort by recency_days DESCENDING.
    NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
    -- F: NTILE does not work here. 97% of customers have exactly 1 order, so
    -- NTILE would split identical one-time buyers into scores 1-4 at random.
    -- Instead the score is the order count, capped at 5.
    MIN(frequency, 5)                          AS f_score,
    -- M: biggest spenders get 5.
    NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
FROM customer_metrics;

-- name: ntile_frequency_check
-- Why F is not scored with NTILE: score buckets 1-4 all hold customers
-- with the same single order, so the score carries no information.
WITH ntiled AS (
    SELECT frequency, NTILE(5) OVER (ORDER BY frequency) AS f_ntile
    FROM customer_rfm
)
SELECT
    f_ntile,
    COUNT(*)       AS customers,
    MIN(frequency) AS min_orders,
    MAX(frequency) AS max_orders
FROM ntiled
GROUP BY f_ntile
ORDER BY f_ntile;

-- name: r_score_ranges
-- What each Recency score means in days.
SELECT r_score, MIN(recency_days) AS min_days, MAX(recency_days) AS max_days, COUNT(*) AS customers
FROM customer_rfm
GROUP BY r_score
ORDER BY r_score;

-- name: m_score_ranges
-- What each Monetary score means in BRL.
SELECT m_score, MIN(monetary) AS min_spend, MAX(monetary) AS max_spend, COUNT(*) AS customers
FROM customer_rfm
GROUP BY m_score
ORDER BY m_score;


/* =====================================================================
   STEP 8 — RFM SEGMENTS
   Rules are checked top-down; the first match wins.
   ===================================================================== */

DROP VIEW IF EXISTS customer_segments;

CREATE VIEW customer_segments AS
SELECT
    *,
    CASE
        WHEN f_score >= 2 AND r_score >= 4 THEN 'Champions'        -- repeat buyers, bought recently
        WHEN f_score >= 2                  THEN 'Loyal'            -- repeat buyers, not recent
        WHEN r_score >= 4 AND m_score >= 4 THEN 'Promising'        -- new, recent, high spend
        WHEN r_score >= 4                  THEN 'New Customers'    -- new, recent, lower spend
        WHEN r_score >= 2 AND m_score >= 4 THEN 'At Risk'          -- high spend, going quiet
        WHEN r_score >= 2                  THEN 'Hibernating'      -- low spend, going quiet
        ELSE                                    'Lost'             -- oldest 20%, one order
    END AS segment
FROM customer_rfm;

-- name: segment_summary
-- Each segment's share of customers and of revenue.
SELECT
    segment,
    COUNT(*)                                                    AS customers,
    ROUND(100.0 * COUNT(*)      / SUM(COUNT(*))      OVER (), 2) AS pct_customers,
    ROUND(SUM(monetary), 0)                                     AS revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_revenue,
    ROUND(AVG(monetary), 2)                                     AS avg_spend,
    ROUND(AVG(recency_days), 0)                                 AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                    AS avg_orders
FROM customer_segments
GROUP BY segment
ORDER BY revenue DESC;


/* =====================================================================
   STEP 9 — REVENUE CONCENTRATION
   Rank customers by spend; how much revenue comes from the top X%?
   ===================================================================== */

-- name: revenue_concentration
WITH customer_spend AS (
    SELECT customer_unique_id, SUM(order_value) AS spend
    FROM clean_orders
    GROUP BY customer_unique_id
),
ranked_customers AS (
    SELECT
        spend,
        ROW_NUMBER() OVER (ORDER BY spend DESC)                    AS spend_rank,
        COUNT(*)     OVER ()                                       AS total_customers,
        SUM(spend)   OVER (ORDER BY spend DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_revenue,
        SUM(spend)   OVER ()                                       AS total_revenue
    FROM customer_spend
),
cutoffs(top_pct) AS (
    VALUES (1), (5), (10), (20), (50)
)
SELECT
    c.top_pct                                              AS top_pct_of_customers,
    MAX(r.spend_rank)                                      AS customers,
    ROUND(100.0 * MAX(r.running_revenue) / MAX(r.total_revenue), 1) AS pct_of_revenue
FROM cutoffs c
JOIN ranked_customers r
  ON r.spend_rank <= r.total_customers * c.top_pct / 100.0
GROUP BY c.top_pct
ORDER BY c.top_pct;


/* =====================================================================
   STEP 10 (BONUS) — DO LATE DELIVERIES HURT REVIEW SCORES?
   Late = delivered to the customer after the estimated delivery date.
   ===================================================================== */

-- name: late_vs_on_time_reviews
WITH order_reviews AS (             -- a few orders have 2+ reviews; average them
    SELECT order_id, AVG(review_score) AS review_score
    FROM reviews
    GROUP BY order_id
),
delivery_status AS (
    SELECT
        order_id,
        CASE
            WHEN DATE(order_delivered_customer_date) > DATE(order_estimated_delivery_date)
            THEN 'Late' ELSE 'On time'
        END AS delivery_status
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL   -- 8 delivered orders have no delivery date
)
SELECT
    d.delivery_status,
    COUNT(*)                                                         AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS pct_orders,
    ROUND(AVG(r.review_score), 2)                                    AS avg_review_score,
    ROUND(100.0 * AVG(CASE WHEN r.review_score <= 2 THEN 1.0 ELSE 0 END), 1) AS pct_1_or_2_stars
FROM delivery_status d
JOIN order_reviews r ON r.order_id = d.order_id
GROUP BY d.delivery_status
ORDER BY d.delivery_status DESC;

-- name: review_by_days_late
-- The same question in finer buckets: the later the order, the worse the score.
WITH order_reviews AS (
    SELECT order_id, AVG(review_score) AS review_score
    FROM reviews
    GROUP BY order_id
),
delivery_delay AS (
    SELECT
        order_id,
        JULIANDAY(DATE(order_delivered_customer_date))
      - JULIANDAY(DATE(order_estimated_delivery_date)) AS days_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
)
SELECT
    CASE
        WHEN days_late <= -8 THEN '1 8+ days early'
        WHEN days_late <=  0 THEN '2 on time to 7 days early'
        WHEN days_late <=  3 THEN '3 1-3 days late'
        WHEN days_late <=  7 THEN '4 4-7 days late'
        WHEN days_late <= 14 THEN '5 8-14 days late'
        ELSE                      '6 15+ days late'
    END                                     AS delay_bucket,
    COUNT(*)                                AS orders,
    ROUND(AVG(r.review_score), 2)           AS avg_review_score
FROM delivery_delay d
JOIN order_reviews r ON r.order_id = d.order_id
GROUP BY delay_bucket
ORDER BY delay_bucket;

-- name: late_delivery_and_repeat
-- Does a late FIRST order make customers less likely to come back?
WITH first_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                           ORDER BY o.order_purchase_timestamp) AS order_seq,
        COUNT(*)     OVER (PARTITION BY c.customer_unique_id)   AS total_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
)
SELECT
    CASE
        WHEN DATE(order_delivered_customer_date) > DATE(order_estimated_delivery_date)
        THEN 'Late first order' ELSE 'On-time first order'
    END                                                              AS first_order,
    COUNT(*)                                                         AS customers,
    ROUND(100.0 * AVG(CASE WHEN total_orders >= 2 THEN 1.0 ELSE 0 END), 2) AS repeat_rate_pct
FROM first_orders
WHERE order_seq = 1
  AND order_delivered_customer_date IS NOT NULL
GROUP BY first_order
ORDER BY first_order;
