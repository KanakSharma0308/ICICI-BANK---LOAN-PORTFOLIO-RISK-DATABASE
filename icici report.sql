-- ---------------------------------------------------------------------
-- Q1. Portfolio snapshot by product (latest month)
--     Business question: How big is each book and what is the average ticket?
-- ---------------------------------------------------------------------
SELECT  l.product_type,
        COUNT(*)                                         AS live_accounts,
        ROUND(SUM(s.outstanding_principal)/1e7, 2)       AS outstanding_cr,
        ROUND(100.0*SUM(s.outstanding_principal)
              / SUM(SUM(s.outstanding_principal)) OVER (), 1) AS pct_of_book,
        ROUND(AVG(s.outstanding_principal)/1e5, 2)       AS avg_ticket_lakh,
        ROUND(SUM(l.interest_rate*s.outstanding_principal)
              / SUM(s.outstanding_principal), 2)         AS wtd_avg_rate_pct
FROM    monthly_snapshot s
JOIN    loan_accounts l USING (loan_id)
WHERE   s.snapshot_month = '2026-08'
GROUP BY l.product_type
ORDER BY outstanding_cr DESC;


-- ---------------------------------------------------------------------
-- Q2. Gross NPA % and Net NPA % by product (latest month)
--     GNPA% = 90+ DPD outstanding / total outstanding
--     NNPA% = (NPA outstanding - NPA provisions) / (total outstanding - total provisions)
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT  l.product_type,
            s.outstanding_principal                        AS os,
            s.dpd,
            s.outstanding_principal * p.provision_rate     AS provision,
            p.asset_class
    FROM    monthly_snapshot s
    JOIN    loan_accounts l   USING (loan_id)
    JOIN    provision_norms p ON s.dpd BETWEEN p.min_dpd AND p.max_dpd
    WHERE   s.snapshot_month = '2026-08'
)
SELECT  product_type,
        ROUND(SUM(os)/1e7, 2)                                              AS outstanding_cr,
        ROUND(SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)/1e7, 2)                 AS gnpa_cr,
        ROUND(100.0*SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)/SUM(os),2) AS gnpa_pct,
        ROUND(100.0*(SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)
                   - SUM(CASE WHEN dpd >= 90 THEN provision ELSE 0 END))
              /(SUM(os)-SUM(provision)), 2)                                AS nnpa_pct
FROM    base
GROUP BY product_type
UNION ALL
SELECT  'TOTAL BOOK',
        ROUND(SUM(os)/1e7, 2),
        ROUND(SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)/1e7, 2),
        ROUND(100.0*SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)/SUM(os),2),
        ROUND(100.0*(SUM(CASE WHEN dpd >= 90 THEN os ELSE 0 END)
                   - SUM(CASE WHEN dpd >= 90 THEN provision ELSE 0 END))
              /(SUM(os)-SUM(provision)), 2)
FROM    base
ORDER BY gnpa_pct DESC;


-- ---------------------------------------------------------------------
-- Q3. Asset-quality bucket distribution (Standard / SMA-0/1/2 / NPA)
-- ---------------------------------------------------------------------
SELECT  p.dpd_bucket,
        p.asset_class,
        COUNT(*)                                        AS accounts,
        ROUND(SUM(s.outstanding_principal)/1e7, 2)      AS outstanding_cr,
        ROUND(100.0*SUM(s.outstanding_principal)
              / SUM(SUM(s.outstanding_principal)) OVER (), 2) AS pct_of_book
FROM    monthly_snapshot s
JOIN    provision_norms p ON s.dpd BETWEEN p.min_dpd AND p.max_dpd
WHERE   s.snapshot_month = '2026-08'
GROUP BY p.dpd_bucket, p.asset_class, p.min_dpd
ORDER BY p.min_dpd;


-- ---------------------------------------------------------------------
-- Q4. Monthly GNPA trend with month-on-month change (window function LAG)
--     Shows the book seasoning: GNPA rises as new loans age.
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT  snapshot_month,
            SUM(outstanding_principal)                                       AS total_os,
            SUM(CASE WHEN dpd >= 90 THEN outstanding_principal ELSE 0 END)   AS npa_os
    FROM    monthly_snapshot
    GROUP BY snapshot_month
)
SELECT  snapshot_month,
        ROUND(total_os/1e7, 2)                              AS book_cr,
        ROUND(100.0*npa_os/total_os, 2)                     AS gnpa_pct,
        ROUND(100.0*npa_os/total_os
              - LAG(100.0*npa_os/total_os) OVER (ORDER BY snapshot_month), 2) AS mom_change_pp,
        ROUND(AVG(100.0*npa_os/total_os)
              OVER (ORDER BY snapshot_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS gnpa_3m_avg
FROM    monthly
ORDER BY snapshot_month;


-- ---------------------------------------------------------------------
-- Q5. Roll-rate matrix: where do accounts move from one month to the next?
--     (self-join on loan_id and consecutive MOB) - core early-warning tool
-- ---------------------------------------------------------------------
WITH bucketed AS (
    SELECT  loan_id, months_on_book, outstanding_principal,
            CASE WHEN dpd = 0   THEN '0 Current'
                 WHEN dpd <= 30 THEN '1 (1-30)'
                 WHEN dpd <= 60 THEN '2 (31-60)'
                 WHEN dpd <= 89 THEN '3 (61-89)'
                 ELSE                '4 (90+)' END AS bkt
    FROM    monthly_snapshot
)
SELECT  a.bkt                                            AS from_bucket,
        b.bkt                                            AS to_bucket,
        COUNT(*)                                         AS accounts,
        ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (PARTITION BY a.bkt), 1) AS roll_rate_pct
FROM    bucketed a
JOIN    bucketed b ON b.loan_id = a.loan_id
                  AND b.months_on_book = a.months_on_book + 1
GROUP BY a.bkt, b.bkt
ORDER BY a.bkt, b.bkt;


-- ---------------------------------------------------------------------
-- Q6. Vintage analysis: % of accounts 90+ DPD by disbursal half-year cohort
--     and months on book (MOB). Compares how each cohort performs at the same age.
-- ---------------------------------------------------------------------
WITH cohort AS (
    SELECT  s.loan_id, s.months_on_book, s.dpd,
            SUBSTR(l.disbursal_date,1,4) ||
            CASE WHEN CAST(SUBSTR(snapshot_month, 6, 2) AS SIGNED) <= 6 THEN '-H1' ELSE '-H2' END AS vintage
    FROM    monthly_snapshot s
    JOIN    loan_accounts l USING (loan_id)
    WHERE   s.months_on_book IN (3, 6, 9, 12)
)
SELECT  vintage,
        COUNT(DISTINCT loan_id)                                                 AS accounts,
        ROUND(100.0*SUM(CASE WHEN months_on_book=3  AND dpd>=90 THEN 1 ELSE 0 END)
              / NULLIF(SUM(months_on_book=3),0), 2)                             AS npa_pct_mob3,
        ROUND(100.0*SUM(CASE WHEN months_on_book=6  AND dpd>=90 THEN 1 ELSE 0 END)
              / NULLIF(SUM(months_on_book=6),0), 2)                             AS npa_pct_mob6,
        ROUND(100.0*SUM(CASE WHEN months_on_book=9  AND dpd>=90 THEN 1 ELSE 0 END)
              / NULLIF(SUM(months_on_book=9),0), 2)                             AS npa_pct_mob9,
        ROUND(100.0*SUM(CASE WHEN months_on_book=12 AND dpd>=90 THEN 1 ELSE 0 END)
              / NULLIF(SUM(months_on_book=12),0), 2)                            AS npa_pct_mob12
FROM    cohort
GROUP BY vintage
ORDER BY vintage;


-- ---------------------------------------------------------------------
-- Q7. Branch league table - GNPA ranking with region rank and risk quartile
--     (RANK, NTILE, PARTITION BY). Only branches with meaningful exposure.
-- ---------------------------------------------------------------------
WITH branch_stats AS (
    SELECT  b.branch_id, b.branch_name, b.region,
            COUNT(*)                                                        AS accounts,
            SUM(s.outstanding_principal)                                    AS os,
            100.0*SUM(CASE WHEN s.dpd>=90 THEN s.outstanding_principal ELSE 0 END)
                 / SUM(s.outstanding_principal)                             AS gnpa_pct,
            100.0*SUM(CASE WHEN s.dpd BETWEEN 1 AND 89 THEN s.outstanding_principal ELSE 0 END)
                 / SUM(s.outstanding_principal)                             AS sma_pct
    FROM    monthly_snapshot s
    JOIN    loan_accounts l USING (loan_id)
    JOIN    branches b      USING (branch_id)
    WHERE   s.snapshot_month = '2026-08'
    GROUP BY b.branch_id, b.branch_name, b.region
    HAVING  SUM(s.outstanding_principal) > 2e7           -- > Rs 2 crore exposure
)
SELECT  branch_name, region, accounts,
        ROUND(os/1e7,2)                                        AS outstanding_cr,
        ROUND(gnpa_pct,2)                                      AS gnpa_pct,
        ROUND(sma_pct,2)                                       AS sma_pct,
        RANK()  OVER (ORDER BY gnpa_pct DESC)                  AS national_rank_worst,
        RANK()  OVER (PARTITION BY region ORDER BY gnpa_pct DESC) AS region_rank_worst,
        NTILE(4) OVER (ORDER BY gnpa_pct DESC)                 AS risk_quartile   -- 1 = riskiest
FROM    branch_stats
ORDER BY gnpa_pct DESC;


-- ---------------------------------------------------------------------
-- Q8. Credit score band vs default behaviour (risk segmentation)
--     Validates whether the score rank-orders risk: 'ever 90+' rate per band.
-- ---------------------------------------------------------------------
WITH ever_npa AS (
    SELECT loan_id, MAX(CASE WHEN dpd >= 90 THEN 1 ELSE 0 END) AS ever_90
    FROM   monthly_snapshot
    GROUP BY loan_id
)
SELECT  CASE WHEN l.credit_score_at_origination >= 780 THEN 'A: 780+'
             WHEN l.credit_score_at_origination >= 720 THEN 'B: 720-779'
             WHEN l.credit_score_at_origination >= 660 THEN 'C: 660-719'
             ELSE                                           'D: <660' END AS score_band,
        COUNT(*)                                       AS accounts,
        SUM(e.ever_90)                                 AS ever_npa_accounts,
        ROUND(100.0*SUM(e.ever_90)/COUNT(*), 2)        AS ever_npa_rate_pct,
        ROUND(AVG(l.interest_rate), 2)                 AS avg_rate_pct
FROM    loan_accounts l
JOIN    ever_npa e USING (loan_id)
GROUP BY score_band
ORDER BY score_band;


-- ---------------------------------------------------------------------
-- Q9. Provision requirement and coverage (latest month)
--     Provision = outstanding x rate from provision_norms (range join).
--     Provision Coverage Ratio (PCR) = NPA provisions / GNPA.
-- ---------------------------------------------------------------------
WITH prov AS (
    SELECT  l.product_type,
            s.outstanding_principal                     AS os,
            s.outstanding_principal*p.provision_rate    AS provision,
            p.asset_class
    FROM    monthly_snapshot s
    JOIN    loan_accounts l   USING (loan_id)
    JOIN    provision_norms p ON s.dpd BETWEEN p.min_dpd AND p.max_dpd
    WHERE   s.snapshot_month = '2026-08'
)
SELECT  product_type,
        ROUND(SUM(provision)/1e7, 3)                                        AS total_provision_cr,
        ROUND(100.0*SUM(provision)/SUM(os), 2)                              AS provision_pct_of_book,
        ROUND(100.0*SUM(CASE WHEN asset_class='NPA' THEN provision ELSE 0 END)
              / NULLIF(SUM(CASE WHEN asset_class='NPA' THEN os ELSE 0 END),0), 1) AS pcr_pct
FROM    prov
GROUP BY product_type
ORDER BY total_provision_cr DESC;


-- ---------------------------------------------------------------------
-- Q10. Risk-adjusted yield by product
--      Yield (wtd. interest rate) minus a simple annual credit-cost proxy
--      (GNPA% x assumed 45% loss-given-default). Which product earns the most after risk?
-- ---------------------------------------------------------------------
WITH x AS (
    SELECT  l.product_type,
            SUM(l.interest_rate*s.outstanding_principal)/SUM(s.outstanding_principal) AS yield_pct,
            100.0*SUM(CASE WHEN s.dpd>=90 THEN s.outstanding_principal ELSE 0 END)
                 /SUM(s.outstanding_principal)                                        AS gnpa_pct
    FROM    monthly_snapshot s
    JOIN    loan_accounts l USING (loan_id)
    WHERE   s.snapshot_month = '2026-08'
    GROUP BY l.product_type
)
SELECT  product_type,
        ROUND(yield_pct,2)                          AS yield_pct,
        ROUND(gnpa_pct,2)                           AS gnpa_pct,
        ROUND(gnpa_pct*0.45,2)                      AS credit_cost_proxy_pct,
        ROUND(yield_pct - gnpa_pct*0.45,2)          AS risk_adj_yield_pct,
        RANK() OVER (ORDER BY yield_pct - gnpa_pct*0.45 DESC) AS rank_
FROM    x
ORDER BY rank_;


-- ---------------------------------------------------------------------
-- Q11. Cumulative disbursals by product and quarter (running total, window SUM OVER)
-- ---------------------------------------------------------------------
WITH d AS (
    SELECT  product_type,
            SUBSTR(disbursal_date,1,4) || '-Q' ||
            (CONCAT(SUBSTR(disbursal_date,1,4), '-Q', (CAST(SUBSTR(disbursal_date,6,2) AS SIGNED) + 2) DIV 3))   AS disb_qtr,
            SUM(sanctioned_amount)                                AS disbursed
    FROM    loan_accounts
    GROUP BY product_type, disb_qtr
)
SELECT  product_type, disb_qtr,
        ROUND(disbursed/1e7, 2)                                                    AS disbursed_cr,
        ROUND(SUM(disbursed) OVER (PARTITION BY product_type ORDER BY disb_qtr)/1e7, 2) AS cumulative_cr
FROM    d
ORDER BY product_type, disb_qtr;


-- ---------------------------------------------------------------------
-- Q12. Early-warning watchlist: top 10 SMA-2 (61-89 DPD) exposures
--      These are the accounts one bucket away from turning NPA.
-- ---------------------------------------------------------------------
SELECT  l.loan_id, l.product_type, b.branch_name,
        l.credit_score_at_origination                 AS orig_score,
        s.dpd,
        ROUND(s.outstanding_principal/1e5, 2)         AS outstanding_lakh
FROM    monthly_snapshot s
JOIN    loan_accounts l USING (loan_id)
JOIN    branches b      USING (branch_id)
WHERE   s.snapshot_month = '2026-08'
  AND   s.dpd BETWEEN 61 AND 89
ORDER BY s.outstanding_principal DESC
LIMIT   10;