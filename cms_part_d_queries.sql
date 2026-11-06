-- CMS Medicare Part D Drug Spending: Utilization vs. Spending Dynamics
-- Queries 1 to 7, as written and run in MySQL 9.7.0 (Workbench)
-- Table: cms_medicare.cms_part_d_clean (45 rows: 9 drugs x 5 years, 2018-2022)
-- Spending is gross (before manufacturer rebates).
-- Drug identifier: generic_name.
--
-- Rounding note (Queries 5 and 6): MySQL divides with only 4 extra decimals,
-- so claims growth for Empagliflozin prints 508.0 (exact value 507.9) and for
-- Dapagliflozin 429.6 (exact 429.5). To get exact values, multiply first:
--   (claims_2022 - claims_2018) * 100.0 / claims_2018
-- The queries below are kept exactly as they were run.


-- ================================================================
-- Query 1: Data quality check
-- Expected: 45 rows, 9 drugs, 3 categories, 5 years, all NULL counts 0
-- ================================================================
SELECT COUNT(*)                     AS total_rows,
       COUNT(DISTINCT generic_name) AS drugs,
       COUNT(DISTINCT category)     AS categories,
       COUNT(DISTINCT data_year)    AS years
FROM cms_medicare.cms_part_d_clean;

SELECT COUNT(*) - COUNT(brand_name)          AS null_brand_name,
       COUNT(*) - COUNT(generic_name)        AS null_generic_name,
       COUNT(*) - COUNT(category)            AS null_category,
       COUNT(*) - COUNT(data_year)           AS null_data_year,
       COUNT(*) - COUNT(total_spending)      AS null_total_spending,
       COUNT(*) - COUNT(total_claims)        AS null_total_claims,
       COUNT(*) - COUNT(total_beneficiaries) AS null_total_beneficiaries,
       COUNT(*) - COUNT(avg_spend_per_claim) AS null_avg_spend_per_claim
FROM cms_medicare.cms_part_d_clean;

-- Every drug must have all 5 years. Expected: no rows returned.
-- Self-test: change != to = and you should get all 9 drugs with years_count = 5.
SELECT generic_name, COUNT(DISTINCT data_year) AS years_count
FROM cms_medicare.cms_part_d_clean
GROUP BY generic_name
HAVING COUNT(DISTINCT data_year) != 5;


-- ================================================================
-- Query 2: Total spending per category per year
-- Expected: 15 rows (3 categories x 5 years)
-- ================================================================
SELECT category,
       data_year,
       SUM(total_spending) AS category_year_spending
FROM cms_medicare.cms_part_d_clean
GROUP BY category, data_year
ORDER BY category, data_year;


-- ================================================================
-- Query 3: Rank the 9 drugs by 2022 spending
-- Expected: 1 Apixaban, 2 Dulaglutide, 3 Lenalidomide, 4 Empagliflozin,
--           5 Rivaroxaban, 6 Ibrutinib, 7 Dapagliflozin Propanediol,
--           8 Palbociclib, 9 Rosuvastatin Calcium
-- ================================================================
-- Overall rank
SELECT generic_name,
       category,
       total_spending,
       RANK() OVER (ORDER BY total_spending DESC) AS spend_rank
FROM cms_medicare.cms_part_d_clean
WHERE data_year = 2022
ORDER BY spend_rank ASC;

-- Rank within category (expect 1, 2, 3 inside each category)
SELECT generic_name,
       category,
       total_spending,
       RANK() OVER (PARTITION BY category ORDER BY total_spending DESC) AS spend_rank
FROM cms_medicare.cms_part_d_clean
WHERE data_year = 2022
ORDER BY category, spend_rank;


-- ================================================================
-- Query 4: Spending growth per drug, 2018 to 2022
-- Expected: Empagliflozin +775.5% (highest percent),
--           Apixaban +$10.23B (highest dollar change),
--           Palbociclib +29.3% (lowest percent)
-- ================================================================
WITH yearly AS (
    SELECT generic_name,
           category,
           SUM(CASE WHEN data_year = 2018 THEN total_spending END) AS spend_2018,
           SUM(CASE WHEN data_year = 2022 THEN total_spending END) AS spend_2022
    FROM cms_medicare.cms_part_d_clean
    GROUP BY generic_name, category
)
SELECT generic_name,
       category,
       spend_2018,
       spend_2022,
       spend_2022 - spend_2018 AS spend_change,
       ROUND((spend_2022 - spend_2018) / spend_2018 * 100, 1) AS growth_pct
FROM yearly
ORDER BY growth_pct DESC;


-- ================================================================
-- Query 5: Utilization growth per drug (claims and beneficiaries)
-- Expected: Empagliflozin claims +508.0%, beneficiaries +505.4%
--           Palbociclib claims +2.8%, beneficiaries -12.9% (only drug losing patients)
--           Ibrutinib claims +18.4%, beneficiaries +1.2%
--           Rivaroxaban claims +10.7%, beneficiaries +24.8%
-- ================================================================
WITH yearly AS (
    SELECT generic_name,
           category,
           SUM(CASE WHEN data_year = 2018 THEN total_beneficiaries END) AS beneficiaries_2018,
           SUM(CASE WHEN data_year = 2022 THEN total_beneficiaries END) AS beneficiaries_2022,
           SUM(CASE WHEN data_year = 2018 THEN total_claims END) AS claims_2018,
           SUM(CASE WHEN data_year = 2022 THEN total_claims END) AS claims_2022
    FROM cms_medicare.cms_part_d_clean
    GROUP BY generic_name, category
)
SELECT generic_name,
       category,
       claims_2018,
       claims_2022,
       beneficiaries_2018,
       beneficiaries_2022,
       ROUND((claims_2022 - claims_2018) / claims_2018 * 100, 1) AS claims_growth_pct,
       ROUND((beneficiaries_2022 - beneficiaries_2018) / beneficiaries_2018 * 100, 1) AS beneficiaries_growth_pct
FROM yearly
ORDER BY claims_growth_pct DESC;


-- ================================================================
-- Query 6: Price-driven or volume-driven?
-- Rule: growth gap = spending growth % - claims growth %
--       gap > +10  -> price-driven   (spend per claim rose)
--       gap < -10  -> volume-driven  (spend per claim fell)
--       otherwise  -> balanced
-- The 10-point cutoff is an analyst choice.
-- Expected: 8 drugs price-driven (gaps +26.5 to +267.5),
--           Rosuvastatin Calcium volume-driven (gap about -96)
-- ================================================================
WITH cte1 AS (
    SELECT generic_name,
           category,
           SUM(CASE WHEN data_year = 2018 THEN total_claims END) AS claims_2018,
           SUM(CASE WHEN data_year = 2022 THEN total_claims END) AS claims_2022,
           SUM(CASE WHEN data_year = 2018 THEN total_spending END) AS spend_2018,
           SUM(CASE WHEN data_year = 2022 THEN total_spending END) AS spend_2022
    FROM cms_medicare.cms_part_d_clean
    GROUP BY generic_name, category
),
cte_2 AS (
    SELECT generic_name,
           category,
           ROUND((claims_2022 - claims_2018) / claims_2018 * 100, 1) AS claims_growth_pct,
           ROUND((spend_2022 - spend_2018) / spend_2018 * 100, 1) AS spend_growth_pct
    FROM cte1
)
SELECT generic_name,
       category,
       spend_growth_pct,
       claims_growth_pct,
       spend_growth_pct - claims_growth_pct AS growth_gap,
       CASE WHEN spend_growth_pct - claims_growth_pct > 10 THEN 'price-driven'
            WHEN spend_growth_pct - claims_growth_pct < -10 THEN 'volume-driven'
            ELSE 'balanced'
       END AS main_driver
FROM cte_2
ORDER BY growth_gap DESC;


-- ================================================================
-- Query 7: Each drug's share of its category's 2022 spending
-- Expected: Apixaban 70.49, Rivaroxaban 26.74, Rosuvastatin 2.77;
--           Dulaglutide 42.46, Empagliflozin 39.91, Dapagliflozin 17.63;
--           Lenalidomide 55.28, Ibrutinib 26.58, Palbociclib 18.15
-- Shares inside each category add up to about 100.
-- ================================================================
SELECT brand_name,
       category,
       total_spending AS spending_2022,
       ROUND(
           total_spending * 100.0 /
           SUM(total_spending) OVER (
               PARTITION BY category
           ),
           2
       ) AS category_share_pct
FROM cms_medicare.cms_part_d_clean
WHERE data_year = 2022
ORDER BY category, spending_2022 DESC;