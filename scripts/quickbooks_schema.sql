-- QuickBooks → Supabase Schema
-- Following existing pattern: public.quickbooks_* prefix
-- All tables have qb_id PK, raw_json JSONB, synced_at

-- Customers
CREATE TABLE IF NOT EXISTS quickbooks_customers (
  qb_id TEXT PRIMARY KEY,
  display_name TEXT,
  company_name TEXT,
  given_name TEXT,
  family_name TEXT,
  email TEXT,
  phone TEXT,
  mobile TEXT,
  balance NUMERIC(12,2),
  is_active BOOLEAN DEFAULT true,
  billing_address_line1 TEXT,
  billing_address_city TEXT,
  billing_address_state TEXT,
  billing_address_postal TEXT,
  billing_address_country TEXT,
  notes TEXT,
  taxable BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Invoices
CREATE TABLE IF NOT EXISTS quickbooks_invoices (
  qb_id TEXT PRIMARY KEY,
  doc_number TEXT,
  customer_id TEXT,
  customer_name TEXT,
  txn_date DATE,
  due_date DATE,
  total_amt NUMERIC(12,2),
  balance NUMERIC(12,2),
  status TEXT,
  email_status TEXT,
  print_status TEXT,
  sales_term_id TEXT,
  deposit NUMERIC(12,2),
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_invoices_customer ON quickbooks_invoices(customer_id);
CREATE INDEX IF NOT EXISTS idx_qb_invoices_date ON quickbooks_invoices(txn_date);
CREATE INDEX IF NOT EXISTS idx_qb_invoices_status ON quickbooks_invoices(status);
CREATE INDEX IF NOT EXISTS idx_qb_invoices_doc_number ON quickbooks_invoices(doc_number);

-- Payments
CREATE TABLE IF NOT EXISTS quickbooks_payments (
  qb_id TEXT PRIMARY KEY,
  customer_id TEXT,
  customer_name TEXT,
  txn_date DATE,
  total_amt NUMERIC(12,2),
  unapplied_amt NUMERIC(12,2),
  payment_method TEXT,
  payment_ref_num TEXT,
  deposit_to_account_id TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_payments_customer ON quickbooks_payments(customer_id);
CREATE INDEX IF NOT EXISTS idx_qb_payments_date ON quickbooks_payments(txn_date);

-- Items (service catalog)
CREATE TABLE IF NOT EXISTS quickbooks_items (
  qb_id TEXT PRIMARY KEY,
  name TEXT,
  description TEXT,
  item_type TEXT,
  unit_price NUMERIC(12,2),
  purchase_cost NUMERIC(12,2),
  income_account_id TEXT,
  expense_account_id TEXT,
  is_active BOOLEAN DEFAULT true,
  taxable BOOLEAN,
  sku TEXT,
  qty_on_hand NUMERIC(12,2),
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Chart of Accounts
CREATE TABLE IF NOT EXISTS quickbooks_accounts (
  qb_id TEXT PRIMARY KEY,
  name TEXT,
  account_type TEXT,
  account_sub_type TEXT,
  classification TEXT,
  current_balance NUMERIC(12,2),
  currency TEXT DEFAULT 'USD',
  is_active BOOLEAN DEFAULT true,
  fully_qualified_name TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_accounts_type ON quickbooks_accounts(account_type);

-- Purchases (expenses)
CREATE TABLE IF NOT EXISTS quickbooks_purchases (
  qb_id TEXT PRIMARY KEY,
  payment_type TEXT,
  txn_date DATE,
  total_amt NUMERIC(12,2),
  account_id TEXT,
  entity_id TEXT,
  entity_type TEXT,
  entity_name TEXT,
  doc_number TEXT,
  private_note TEXT,
  credit BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_purchases_date ON quickbooks_purchases(txn_date);
CREATE INDEX IF NOT EXISTS idx_qb_purchases_entity ON quickbooks_purchases(entity_id);
CREATE INDEX IF NOT EXISTS idx_qb_purchases_type ON quickbooks_purchases(payment_type);

-- Vendors
CREATE TABLE IF NOT EXISTS quickbooks_vendors (
  qb_id TEXT PRIMARY KEY,
  display_name TEXT,
  company_name TEXT,
  given_name TEXT,
  family_name TEXT,
  email TEXT,
  phone TEXT,
  mobile TEXT,
  balance NUMERIC(12,2),
  is_active BOOLEAN DEFAULT true,
  is_1099 BOOLEAN DEFAULT false,
  billing_address_line1 TEXT,
  billing_address_city TEXT,
  billing_address_state TEXT,
  billing_address_postal TEXT,
  tax_identifier TEXT,
  acct_num TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Bills
CREATE TABLE IF NOT EXISTS quickbooks_bills (
  qb_id TEXT PRIMARY KEY,
  vendor_id TEXT,
  vendor_name TEXT,
  txn_date DATE,
  due_date DATE,
  total_amt NUMERIC(12,2),
  balance NUMERIC(12,2),
  doc_number TEXT,
  private_note TEXT,
  ap_account_id TEXT,
  sales_term_id TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_bills_vendor ON quickbooks_bills(vendor_id);
CREATE INDEX IF NOT EXISTS idx_qb_bills_date ON quickbooks_bills(txn_date);

-- Credit Memos
CREATE TABLE IF NOT EXISTS quickbooks_credit_memos (
  qb_id TEXT PRIMARY KEY,
  customer_id TEXT,
  customer_name TEXT,
  txn_date DATE,
  total_amt NUMERIC(12,2),
  remaining_credit NUMERIC(12,2),
  doc_number TEXT,
  private_note TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Journal Entries
CREATE TABLE IF NOT EXISTS quickbooks_journal_entries (
  qb_id TEXT PRIMARY KEY,
  txn_date DATE,
  doc_number TEXT,
  total_amt NUMERIC(12,2),
  adjustment BOOLEAN DEFAULT false,
  private_note TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Transfers
CREATE TABLE IF NOT EXISTS quickbooks_transfers (
  qb_id TEXT PRIMARY KEY,
  txn_date DATE,
  amount NUMERIC(12,2),
  from_account_id TEXT,
  from_account_name TEXT,
  to_account_id TEXT,
  to_account_name TEXT,
  private_note TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Deposits
CREATE TABLE IF NOT EXISTS quickbooks_deposits (
  qb_id TEXT PRIMARY KEY,
  txn_date DATE,
  total_amt NUMERIC(12,2),
  deposit_to_account_id TEXT,
  deposit_to_account_name TEXT,
  private_note TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_qb_deposits_date ON quickbooks_deposits(txn_date);

-- Refund Receipts
CREATE TABLE IF NOT EXISTS quickbooks_refund_receipts (
  qb_id TEXT PRIMARY KEY,
  customer_id TEXT,
  customer_name TEXT,
  txn_date DATE,
  total_amt NUMERIC(12,2),
  doc_number TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Payment Methods
CREATE TABLE IF NOT EXISTS quickbooks_payment_methods (
  qb_id TEXT PRIMARY KEY,
  name TEXT,
  payment_type TEXT,
  is_active BOOLEAN DEFAULT true,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tax Codes
CREATE TABLE IF NOT EXISTS quickbooks_tax_codes (
  qb_id TEXT PRIMARY KEY,
  name TEXT,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  taxable BOOLEAN,
  tax_group BOOLEAN,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Terms (Net 30, Due on Receipt, etc.)
CREATE TABLE IF NOT EXISTS quickbooks_terms (
  qb_id TEXT PRIMARY KEY,
  name TEXT,
  due_days INTEGER,
  discount_percent NUMERIC(5,2),
  discount_days INTEGER,
  is_active BOOLEAN DEFAULT true,
  raw_json JSONB,
  synced_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sync log (audit trail)
CREATE TABLE IF NOT EXISTS quickbooks_sync_log (
  id BIGSERIAL PRIMARY KEY,
  entity_type TEXT NOT NULL,
  records_synced INTEGER DEFAULT 0,
  records_failed INTEGER DEFAULT 0,
  duration_ms INTEGER,
  status TEXT DEFAULT 'success',
  error_message TEXT,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_qb_sync_log_entity ON quickbooks_sync_log(entity_type);
CREATE INDEX IF NOT EXISTS idx_qb_sync_log_started ON quickbooks_sync_log(started_at DESC);
