ICICI BANK - LOAN PORTFOLIO RISK DATABASE (SQL)
=====================================================================
 
A MySQL database script that creates and fills a small retail loan
portfolio: branches, customers, loan accounts, monthly loan snapshots
(with days past due) and a provisioning matrix.
 
The data is built for practising credit risk reporting in SQL, such as
NPA tracking, provisioning, delinquency buckets and vintage analysis.
 
Built as a learning project for a banking / credit analyst role.
 
IMPORTANT NOTE
--------------
- All data (customers, loans, balances, DPD) is SYNTHETIC and randomly
  generated. It is not real customer or bank data.
- The provisioning rates are my own illustrative assumption. They are
  NOT the exact RBI provisioning schedule or ICICI Bank's actual policy.
- This project is not affiliated with or endorsed by ICICI Bank.
 
 
---------------------------------------------------------------------
1. WHAT IS IN THIS REPO
---------------------------------------------------------------------
icici_report_table.sql   Full script: creates the database, tables,
                         indexes and inserts all the data
README.txt               This file
 
The script:
  1. Creates the database  loan_db
  2. Drops and re-creates all 5 tables (safe to run again)
  3. Creates 3 indexes
  4. Inserts all the sample data
 
 
---------------------------------------------------------------------
2. DATABASE SIZE
---------------------------------------------------------------------
  Table              Rows    What it holds
  -----------------  ------  ---------------------------------------
  branches           18      Branches across 5 regions
  customers          380     Age, employment type, annual income
  loan_accounts      450     One row per loan (origination details)
  monthly_snapshot   6,198   One row per loan per month-end
  provision_norms    6       DPD buckets with provision rates
 
  Snapshot period     : Aug 2024 to Aug 2026
  Loan disbursal dates: Jul 2024 to Jun 2026
  Products            : Home, Auto, Personal, Education, Business
  Regions             : North, South, East, West, Central
 
 
---------------------------------------------------------------------
3. TABLE STRUCTURE
---------------------------------------------------------------------
branches
  branch_id (PK), branch_name, city, state,
  region (North / South / East / West / Central)
 
customers
  customer_id (PK), age,
  employment_type (Salaried / Self-Employed),
  annual_income (INR)
 
loan_accounts
  loan_id (PK), customer_id (FK), branch_id (FK), product_type,
  disbursal_date (yyyy-mm-dd), sanctioned_amount (INR),
  tenure_months, interest_rate (% p.a.),
  credit_score_at_origination (300-900),
  secured_flag (1 = secured, 0 = unsecured)
 
monthly_snapshot
  loan_id (FK), snapshot_month (yyyy-mm),
  months_on_book (MOB), outstanding_principal (INR),
  dpd (days past due at month-end)
  Primary key: (loan_id, snapshot_month)
 
provision_norms
  dpd_bucket (PK), min_dpd, max_dpd, provision_rate, asset_class
 
Relationships:
  customers 1 --- many loan_accounts
  branches  1 --- many loan_accounts
  loan_accounts 1 --- many monthly_snapshot
 
Indexes:
  idx_snap_month     on monthly_snapshot(snapshot_month)
  idx_loans_branch   on loan_accounts(branch_id)
  idx_loans_product  on loan_accounts(product_type)
 
 
---------------------------------------------------------------------
4. PROVISIONING MATRIX USED (ASSUMPTION)
---------------------------------------------------------------------
  Bucket            DPD range     Provision   Asset class
  Standard          0             0.4%        Standard
  SMA-0             1 - 30        1%          Special Mention
  SMA-1             31 - 60       5%          Special Mention
  SMA-2             61 - 89       15%         Special Mention
  NPA-Substandard   90 - 365      15%         NPA
  NPA-Doubtful      366+          40%         NPA
 
A loan with DPD of 90 days or more is treated as an NPA.
 
 
---------------------------------------------------------------------
5. HOW TO RUN
---------------------------------------------------------------------
Option A - MySQL command line:
  mysql -u root -p < icici_report_table.sql
 
Option B - MySQL Workbench:
  File > Open SQL Script > select icici_report_table.sql > run it.
 
Then use the database:
  USE loan_db;
  SELECT COUNT(*) FROM loan_accounts;     -- should return 450
 
Note: the script starts with CREATE DATABASE and USE, which are MySQL
statements. For SQLite or PostgreSQL, remove those two lines and adjust
the syntax if needed.
 
 
---------------------------------------------------------------------
6. SAMPLE QUERIES
---------------------------------------------------------------------
Gross NPA % by product (latest month):
 
  SELECT l.product_type,
         ROUND(100.0 * SUM(CASE WHEN s.dpd >= 90
                                THEN s.outstanding_principal ELSE 0 END)
               / SUM(s.outstanding_principal), 2) AS gnpa_pct
  FROM monthly_snapshot s
  JOIN loan_accounts l ON l.loan_id = s.loan_id
  WHERE s.snapshot_month = '2026-08'
  GROUP BY l.product_type
  ORDER BY gnpa_pct DESC;
 
Provision required by bucket (latest month):
 
  SELECT p.dpd_bucket, p.asset_class,
         COUNT(*) AS loans,
         ROUND(SUM(s.outstanding_principal * p.provision_rate)) AS provision
  FROM monthly_snapshot s
  JOIN provision_norms p
    ON s.dpd BETWEEN p.min_dpd AND p.max_dpd
  WHERE s.snapshot_month = '2026-08'
  GROUP BY p.dpd_bucket, p.asset_class, p.min_dpd
  ORDER BY p.min_dpd;
 
Outstanding by region (in crore, latest month):
 
  SELECT b.region,
         ROUND(SUM(s.outstanding_principal) / 10000000.0, 2) AS outstanding_cr
  FROM monthly_snapshot s
  JOIN loan_accounts l ON l.loan_id = s.loan_id
  JOIN branches b ON b.branch_id = l.branch_id
  WHERE s.snapshot_month = '2026-08'
  GROUP BY b.region;
 
 
---------------------------------------------------------------------
7. KEY NUMBERS FROM THE SAMPLE DATA (AUG 2026)
---------------------------------------------------------------------
  Active loans (Aug 2026)        : 446 of 450
  Total outstanding principal    : Rs 82.39 crore
  NPA accounts (DPD 90+)         : 12 loans, Rs 2.20 crore
  Gross NPA ratio                : 2.68%
  Total provision (assumed rates): Rs 89.2 lakh (1.08% of outstanding)
 
  Gross NPA % by product:
    Business Loan    7.56%
    Personal Loan    4.77%
    Education Loan   1.98%
    Home Loan        0.45%
    Auto Loan        0.00%
 
  Observations:
    - Unsecured products (Business, Personal) carry most of the NPAs,
      while secured Auto and Home loans are much cleaner.
    - Most of the provision comes from the 12 NPA accounts, although
      they are only a small part of the total outstanding.
 
 
---------------------------------------------------------------------
8. SKILLS PRACTISED
---------------------------------------------------------------------
  - Database design: primary keys, foreign keys, CHECK constraints
  - Joins across 3-4 tables, including range joins (BETWEEN)
  - Conditional aggregation (CASE WHEN inside SUM)
  - Time-series analysis on monthly snapshot data
  - Banking concepts: DPD, SMA buckets, NPA, GNPA, provisioning,
    months on book (MOB), secured vs unsecured lending
 
 
---------------------------------------------------------------------
9. LIMITATIONS
---------------------------------------------------------------------
  - Data is synthetic, so results are only for demonstration.
  - Dates are stored as text (yyyy-mm-dd and yyyy-mm). They sort
    correctly, but are not DATE columns.
  - Provision rates are assumptions, and there is no write-off,
    recovery or restructuring data.
  - Four loans have no snapshot for Aug 2026 (closed earlier).
