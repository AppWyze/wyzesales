-- ============================================================================
-- WyzeSales — SYNTHETIC TEST DATA (NOT a schema migration)
-- ============================================================================
-- Populates realistic-looking demo data for the WCSA ("Water Components SA")
-- client so every screen in the app has something meaningful to show while
-- the real WyzeSalesExtract pipeline is not yet feeding Staging.
--
-- SCOPE / SAFETY:
--   * Only ever touches the client with code = 'WCSA'. If that client row
--     does not exist yet, this script creates it (so it also works as a
--     from-scratch bootstrap on a brand new project).
--   * Reference data (branches/sales_reps/customers/categories/suppliers/
--     items) is inserted with ON CONFLICT DO NOTHING — safe to re-run, never
--     clobbers rows you've since edited by hand in the app.
--   * Fact/budget/forecast data (sales_document_facts/budget_figures/
--     sales_forecast) is fully derived, so this script deletes WCSA's rows
--     in those three tables and reinserts — the same "safe to replace
--     wholesale" pattern the real extract already uses for these tables.
--     Re-running just regenerates a fresh, consistent dataset.
--   * Wrapped in a single transaction — if anything fails partway, nothing
--     is committed.
--
-- DO NOT run this against a project with real WCSA data you want to keep —
-- it will delete every WCSA sales_document_facts/budget_figures/
-- sales_forecast row. Intended for wyzesales-staging only.
--
-- Reproducible: setseed() fixes the RNG so re-running produces the exact
-- same numbers (useful for diffing/debugging), not just "some" numbers.
-- ============================================================================

begin;

select setseed(0.42);

do $$
declare
  v_client_id       uuid;
  v_branches        text[] := array['JHB','CPT','DBN'];
  v_reps            text[] := array['R01','R02','R03','R04','R05','44'];
  v_categories      text[] := array['PUMP','VALV','PIPE','FILT','ELEC','ACC'];
  v_fiscal_months   text[] := array['Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec','Jan','Feb'];
  v_dimensions      text[] := array['sales_person','customer','item','category','branch','company'];

  v_customer_codes  text[];
  v_customer_attr   boolean[];
  v_customer_rep    text[];
  v_item_codes      text[];
  v_item_cost       numeric[];
  v_item_price      numeric[];
  v_item_dept       text[];

  v_month           date;
  v_month_end       date := date_trunc('month', current_date)::date;
  v_month_idx       int  := 0;
  v_lines_this_month int;
  -- 2026-09-03, Craig: noticed the Sales Analysis Target overlay has nothing
  -- to show for the current (still in-progress) fiscal month and asked
  -- whether it's because there's no data yet for it. It's exactly that —
  -- v_dimension_performance/fn_dimension_performance_filtered (schema/021)
  -- build off actual sales first and LEFT JOIN budget/forecast onto that, so
  -- a fiscal month with zero actual rows never surfaces a target either,
  -- regardless of a budget figure existing for that month label. Beyond
  -- just adding a few rows for the current month, re-running this script
  -- itself has always had a latent bug here: this whole loop is written as
  -- if every month is complete, spreading each month's documents across
  -- ~27 days at random — for the CURRENT month, re-running this on (say) day
  -- 3 of a new month would backdate invoices onto days 4-27 that haven't
  -- happened yet. v_is_current_month/v_days_elapsed/v_days_in_month/
  -- v_day_span/v_prorate_factor below fix both at once: the current month's
  -- volume is scaled down to the fraction of it actually elapsed, and every
  -- doc_date for that month is confined to days 1..v_days_elapsed — so this
  -- script is now safe to re-run on any day of any month, always producing
  -- a realistic partial month rather than either skipping the current month
  -- entirely (if run before it started) or inventing future transactions.
  v_is_current_month boolean;
  v_days_elapsed    int;
  v_days_in_month   int;
  v_day_span        int;
  v_prorate_factor  numeric;
  v_i               int;
  v_item_idx        int;
  v_cust_idx        int;
  v_rep             text;
  v_branch          text;
  v_qty             numeric;
  v_unit_price      numeric;
  v_unit_cost       numeric;
  v_value           numeric;
  v_cost            numeric;
  v_discount        numeric;
  v_doc_seq         int;
  v_credit_chance   numeric;

  v_dim             text;
  v_entities        text[];
  v_entity          text;
  v_fm              text;
  v_hist_avg        numeric;
begin
  -- --------------------------------------------------------------------
  -- 1. Resolve or create the WCSA client
  -- --------------------------------------------------------------------
  select id into v_client_id from clients where code = 'WCSA';
  if v_client_id is null then
    insert into clients (code, name) values ('WCSA', 'Water Components SA')
    returning id into v_client_id;
  end if;

  insert into fiscal_year_settings (client_id, start_month)
  values (v_client_id, 3)
  on conflict (client_id) do nothing;

  insert into forecast_settings (client_id)
  values (v_client_id)
  on conflict (client_id) do nothing;

  -- --------------------------------------------------------------------
  -- 2. Reference data
  -- --------------------------------------------------------------------
  insert into branches (client_id, code, display_code, name) values
    (v_client_id, 'JHB', 'JHB', 'Johannesburg'),
    (v_client_id, 'CPT', 'CPT', 'Cape Town'),
    (v_client_id, 'DBN', 'DBN', 'Durban')
  on conflict (client_id, code) do nothing;

  insert into sales_reps (client_id, rep_code, name) values
    (v_client_id, 'R01', 'Johan Botha'),
    (v_client_id, 'R02', 'Sarah Naidoo'),
    (v_client_id, 'R03', 'Pieter van Wyk'),
    (v_client_id, 'R04', 'Thandiwe Khumalo'),
    (v_client_id, 'R05', 'Mark Fischer'),
    (v_client_id, '44',  'Retail Counter')
  on conflict (client_id, rep_code) do nothing;

  insert into categories (client_id, department_code, name) values
    (v_client_id, 'PUMP', 'Pumps'),
    (v_client_id, 'VALV', 'Valves'),
    (v_client_id, 'PIPE', 'Piping & Fittings'),
    (v_client_id, 'FILT', 'Filtration'),
    (v_client_id, 'ELEC', 'Electrical & Controls'),
    (v_client_id, 'ACC',  'Accessories')
  on conflict (client_id, department_code) do nothing;

  insert into suppliers (client_id, account_code, name) values
    (v_client_id, 'SUP01', 'Grundfos SA'),
    (v_client_id, 'SUP02', 'Xylem Water Solutions'),
    (v_client_id, 'SUP03', 'DN Fittings CC'),
    (v_client_id, 'SUP04', 'Pentair Filtration'),
    (v_client_id, 'SUP05', 'Schneider Electric')
  on conflict (client_id, account_code) do nothing;

  insert into customers (client_id, code, name, assigned_rep_code, attribute_to_assigned_rep) values
    (v_client_id, 'CUS001', 'Rand Water Board',            'R01', true),
    (v_client_id, 'CUS002', 'Johannesburg City Utilities',  'R01', true),
    (v_client_id, 'CUS003', 'Ekurhuleni Metro Water',       'R02', true),
    (v_client_id, 'CUS004', 'Cape Town Bulk Water',         'R02', true),
    (v_client_id, 'CUS005', 'Overberg Irrigation Co-op',    'R03', true),
    (v_client_id, 'CUS006', 'eThekwini Water & Sanitation', 'R04', true),
    (v_client_id, 'CUS007', 'Umgeni Water',                 'R04', true),
    (v_client_id, 'CUS008', 'Sasol Secunda Plant',          'R05', true),
    (v_client_id, 'CUS009', 'Tshwane Water Services',       'R01', false),
    (v_client_id, 'CUS010', 'Mangaung Metro',                'R02', false),
    (v_client_id, 'CUS011', 'Buffalo City Water',            'R03', false),
    (v_client_id, 'CUS012', 'Nelson Mandela Bay Utilities',  'R03', false),
    (v_client_id, 'CUS013', 'Karoo Bottling Co',             null,  false),
    (v_client_id, 'CUS014', 'Highveld Agri Supplies',        null,  false),
    (v_client_id, 'CUS015', 'Lowveld Estates',               null,  false),
    (v_client_id, 'CUS016', 'Garden Route Municipality',     'R05', false),
    (v_client_id, 'CUS017', 'West Coast Fisheries',          null,  false),
    (v_client_id, 'CUS018', 'Free State Grain Co-op',        null,  false),
    (v_client_id, 'CUS019', 'Walk-in / Counter Sales',       '44',  false),
    (v_client_id, 'CUS020', 'Vaal Industrial Park',          'R05', false)
  on conflict (client_id, code) do nothing;

  insert into items (client_id, code, name, department_code, supplier_account_code, default_cost, default_sell_price) values
    (v_client_id, 'ITM0001', '40mm Centrifugal Pump',            'PUMP','SUP01', 2400, 3600),
    (v_client_id, 'ITM0002', '80mm Centrifugal Pump',             'PUMP','SUP01', 4800, 7100),
    (v_client_id, 'ITM0003', 'Submersible Borehole Pump 1.5kW',   'PUMP','SUP01', 6200, 9400),
    (v_client_id, 'ITM0004', 'Submersible Borehole Pump 3kW',     'PUMP','SUP01', 9800,14600),
    (v_client_id, 'ITM0005', 'Booster Pump Set Duplex',           'PUMP','SUP02',15200,22500),
    (v_client_id, 'ITM0006', 'Multistage Vertical Pump',          'PUMP','SUP02',11400,17000),
    (v_client_id, 'ITM0007', 'Variable Speed Drive Pump Unit',    'PUMP','SUP02',18600,27800),
    (v_client_id, 'ITM0008', 'Gate Valve 50mm',                   'VALV','SUP03',  340,  560),
    (v_client_id, 'ITM0009', 'Gate Valve 100mm',                  'VALV','SUP03',  780, 1250),
    (v_client_id, 'ITM0010', 'Butterfly Valve 150mm',             'VALV','SUP03', 1450, 2300),
    (v_client_id, 'ITM0011', 'Check Valve 50mm',                  'VALV','SUP03',  290,  480),
    (v_client_id, 'ITM0012', 'Pressure Reducing Valve',           'VALV','SUP02', 2100, 3300),
    (v_client_id, 'ITM0013', 'Ball Valve 25mm',                   'VALV','SUP03',  120,  210),
    (v_client_id, 'ITM0014', 'Solenoid Valve 220V',               'VALV','SUP05',  560,  920),
    (v_client_id, 'ITM0015', 'HDPE Pipe 110mm (6m)',              'PIPE','SUP03',  680, 1050),
    (v_client_id, 'ITM0016', 'HDPE Pipe 160mm (6m)',              'PIPE','SUP03', 1240, 1900),
    (v_client_id, 'ITM0017', 'uPVC Pipe 50mm (6m)',                'PIPE','SUP03',  180,  310),
    (v_client_id, 'ITM0018', 'uPVC Pipe 110mm (6m)',              'PIPE','SUP03',  420,  680),
    (v_client_id, 'ITM0019', 'Flange Coupling 100mm',             'PIPE','SUP03',  310,  520),
    (v_client_id, 'ITM0020', 'Pipe Reducer 100x50mm',             'PIPE','SUP03',  145,  240),
    (v_client_id, 'ITM0021', 'Elbow Fitting 90deg 100mm',         'PIPE','SUP03',   95,  165),
    (v_client_id, 'ITM0022', 'Cartridge Filter Housing 20"',      'FILT','SUP04',  890, 1420),
    (v_client_id, 'ITM0023', 'Sediment Filter Cartridge 5 micron','FILT','SUP04',   65,  120),
    (v_client_id, 'ITM0024', 'Reverse Osmosis Membrane 4040',     'FILT','SUP04', 1850, 2900),
    (v_client_id, 'ITM0025', 'Sand Media Filter Vessel',          'FILT','SUP04', 6400, 9800),
    (v_client_id, 'ITM0026', 'Activated Carbon Filter Tank',      'FILT','SUP04', 5200, 7900),
    (v_client_id, 'ITM0027', 'UV Sterilizer Unit',                'FILT','SUP04', 3600, 5600),
    (v_client_id, 'ITM0028', 'Pump Control Panel 3-phase',        'ELEC','SUP05', 8200,12400),
    (v_client_id, 'ITM0029', 'Level Sensor Float Switch',         'ELEC','SUP05',  210,  380),
    (v_client_id, 'ITM0030', 'Pressure Transmitter 4-20mA',       'ELEC','SUP05',  980, 1550),
    (v_client_id, 'ITM0031', 'VFD Drive 5.5kW',                   'ELEC','SUP05', 6800,10200),
    (v_client_id, 'ITM0032', 'Motor Starter Contactor',           'ELEC','SUP05',  460,  760),
    (v_client_id, 'ITM0033', 'Flow Meter Electromagnetic 50mm',   'ELEC','SUP05', 4200, 6500),
    (v_client_id, 'ITM0034', 'Pipe Clamp Set 100mm',              'ACC', 'SUP03',   85,  150),
    (v_client_id, 'ITM0035', 'Rubber Gasket Kit',                 'ACC', 'SUP03',   45,   85),
    (v_client_id, 'ITM0036', 'PTFE Thread Tape (pack of 10)',     'ACC', 'SUP03',   28,   55),
    (v_client_id, 'ITM0037', 'Mounting Bracket Heavy Duty',       'ACC', 'SUP01',  120,  210),
    (v_client_id, 'ITM0038', 'Pressure Gauge 0-10 bar',           'ACC', 'SUP05',  190,  320),
    (v_client_id, 'ITM0039', 'Anti-Vibration Mount',              'ACC', 'SUP01',  160,  270),
    (v_client_id, 'ITM0040', 'Tool Kit Pump Maintenance',         'ACC', 'SUP01',  850, 1350)
  on conflict (client_id, code) do nothing;

  -- --------------------------------------------------------------------
  -- 3. Wipe previously-generated derived data for this client
  -- --------------------------------------------------------------------
  delete from sales_document_facts where client_id = v_client_id;
  delete from budget_figures       where client_id = v_client_id;
  delete from sales_forecast       where client_id = v_client_id;

  -- --------------------------------------------------------------------
  -- 4. Load reference arrays for random selection below
  -- --------------------------------------------------------------------
  select array_agg(code order by code), array_agg(attribute_to_assigned_rep order by code),
         array_agg(assigned_rep_code order by code)
    into v_customer_codes, v_customer_attr, v_customer_rep
    from customers where client_id = v_client_id;

  select array_agg(code order by code), array_agg(default_cost order by code),
         array_agg(default_sell_price order by code), array_agg(department_code order by code)
    into v_item_codes, v_item_cost, v_item_price, v_item_dept
    from items where client_id = v_client_id;

  -- --------------------------------------------------------------------
  -- 5. Generate sales_document_facts, one calendar month at a time, from
  --    FY2025's first month (Mar 2024) through the current month. A mild
  --    upward trend + simple seasonality keeps YTD Comparative and the
  --    forecast series from being perfectly flat.
  -- --------------------------------------------------------------------
  v_month := date '2024-03-01';
  while v_month <= v_month_end loop
    v_month_idx := v_month_idx + 1;

    -- Is this iteration the current, still-in-progress calendar month? If
    -- so, work out how much of it has actually elapsed so volume and
    -- document dates below can be scaled down to match — see the
    -- v_is_current_month declaration above for why.
    v_is_current_month := (v_month = v_month_end);
    if v_is_current_month then
      v_days_elapsed   := (current_date - v_month) + 1;
      v_days_in_month  := extract(day from (date_trunc('month', v_month) + interval '1 month' - interval '1 day'))::int;
      v_day_span       := v_days_elapsed;
      v_prorate_factor := v_days_elapsed::numeric / v_days_in_month;
    else
      v_days_elapsed   := null;
      v_days_in_month  := null;
      v_day_span       := 27;
      v_prorate_factor := 1;
    end if;

    -- Base line count grows slowly release-over-release and dips in
    -- Dec/Jan (Southern-hemisphere summer slowdown), picks up Mar/Apr.
    v_lines_this_month := (55 + v_month_idx / 2)::int
      + (case extract(month from v_month)::int
           when 12 then -20 when 1 then -18
           when 3 then 10 when 4 then 8
           else 0
         end)
      + (floor(random() * 10) - 5)::int;
    if v_lines_this_month < 20 then
      v_lines_this_month := 20;
    end if;
    -- Scale a genuinely complete month's line count down to whatever
    -- fraction of the current month has actually elapsed (e.g. 3 of 30 days
    -- in) rather than generating a full month's worth of invoices dated
    -- into days that haven't happened yet.
    if v_is_current_month then
      v_lines_this_month := greatest(1, round(v_lines_this_month * v_prorate_factor)::int);
    end if;

    v_doc_seq := 0;

    for v_i in 1..v_lines_this_month loop
      v_doc_seq := v_doc_seq + 1;
      v_item_idx := 1 + floor(random() * array_length(v_item_codes, 1))::int;
      v_cust_idx := 1 + floor(random() * array_length(v_customer_codes, 1))::int;
      v_branch   := v_branches[1 + floor(random() * array_length(v_branches, 1))::int];

      if v_customer_attr[v_cust_idx] and v_customer_rep[v_cust_idx] is not null then
        v_rep := v_customer_rep[v_cust_idx];
      else
        v_rep := v_reps[1 + floor(random() * array_length(v_reps, 1))::int];
      end if;

      v_qty        := 1 + floor(random() * 15);
      v_unit_price := v_item_price[v_item_idx] * (0.9 + random() * 0.2);
      v_unit_cost  := v_item_cost[v_item_idx]  * (0.95 + random() * 0.1);
      v_value      := round(v_qty * v_unit_price, 2);
      v_cost       := round(v_qty * v_unit_cost, 2);
      v_discount   := case when random() < 0.15 then round((v_value * random() * 0.05)::numeric, 2) else 0 end;

      insert into sales_document_facts
        (client_id, document_kind, document, account_code, doc_date, invoice_rep_code,
         item_code, warehouse_code, quantity, value, cost, discount_amount)
      values
        (v_client_id, 'invoice',
         'INV' || to_char(v_month, 'YYMM') || lpad(v_doc_seq::text, 4, '0'),
         v_customer_codes[v_cust_idx], v_month + (floor(random() * v_day_span))::int,
         v_rep, v_item_codes[v_item_idx], v_branch, v_qty, v_value - v_discount, v_cost, v_discount);

      -- ~4% of invoice lines get a partial credit note in the same month.
      v_credit_chance := random();
      if v_credit_chance < 0.04 then
        insert into sales_document_facts
          (client_id, document_kind, document, account_code, doc_date, invoice_rep_code,
           item_code, warehouse_code, quantity, value, cost, discount_amount)
        values
          (v_client_id, 'credit_note',
           'CRN' || to_char(v_month, 'YYMM') || lpad(v_doc_seq::text, 4, '0'),
           v_customer_codes[v_cust_idx], v_month + (floor(random() * v_day_span))::int,
           v_rep, v_item_codes[v_item_idx], v_branch,
           -round(v_qty * 0.3, 0), -round(v_value * 0.3, 2), -round(v_cost * 0.3, 2), 0);
      end if;
    end loop;

    -- Quotes and sales orders: pending/potential business, excluded from
    -- the sales rollup views but shown on the Quote/Sales Order screens.
    -- Same proration as the invoice count above — a partial current month
    -- shouldn't have a full month's worth of pending quotes either.
    for v_i in 1..greatest(1, round((10 + floor(random() * 8)) * v_prorate_factor))::int loop
      v_item_idx := 1 + floor(random() * array_length(v_item_codes, 1))::int;
      v_cust_idx := 1 + floor(random() * array_length(v_customer_codes, 1))::int;
      v_branch   := v_branches[1 + floor(random() * array_length(v_branches, 1))::int];
      v_rep      := v_reps[1 + floor(random() * array_length(v_reps, 1))::int];
      v_qty      := 1 + floor(random() * 10);
      v_value    := round((v_qty * v_item_price[v_item_idx] * (0.9 + random() * 0.2))::numeric, 2);
      v_cost     := round((v_qty * v_item_cost[v_item_idx] * (0.95 + random() * 0.1))::numeric, 2);

      insert into sales_document_facts
        (client_id, document_kind, document, account_code, doc_date, invoice_rep_code,
         item_code, warehouse_code, quantity, value, cost, discount_amount)
      values
        (v_client_id, 'quote',
         'QTE' || to_char(v_month, 'YYMM') || lpad(v_i::text, 4, '0'),
         v_customer_codes[v_cust_idx], v_month + (floor(random() * v_day_span))::int,
         v_rep, v_item_codes[v_item_idx], v_branch, v_qty, v_value, v_cost, 0);
    end loop;

    for v_i in 1..greatest(1, round((8 + floor(random() * 6)) * v_prorate_factor))::int loop
      v_item_idx := 1 + floor(random() * array_length(v_item_codes, 1))::int;
      v_cust_idx := 1 + floor(random() * array_length(v_customer_codes, 1))::int;
      v_branch   := v_branches[1 + floor(random() * array_length(v_branches, 1))::int];
      v_rep      := v_reps[1 + floor(random() * array_length(v_reps, 1))::int];
      v_qty      := 1 + floor(random() * 10);
      v_value    := round((v_qty * v_item_price[v_item_idx] * (0.9 + random() * 0.2))::numeric, 2);
      v_cost     := round((v_qty * v_item_cost[v_item_idx] * (0.95 + random() * 0.1))::numeric, 2);

      insert into sales_document_facts
        (client_id, document_kind, document, account_code, doc_date, invoice_rep_code,
         item_code, warehouse_code, quantity, value, cost, discount_amount)
      values
        (v_client_id, 'sales_order',
         'SOR' || to_char(v_month, 'YYMM') || lpad(v_i::text, 4, '0'),
         v_customer_codes[v_cust_idx], v_month + (floor(random() * v_day_span))::int,
         v_rep, v_item_codes[v_item_idx], v_branch, v_qty, v_value, v_cost, 0);
    end loop;

    v_month := v_month + interval '1 month';
  end loop;

  -- --------------------------------------------------------------------
  -- 6. Budgets + forecast for the CURRENT fiscal year, derived from each
  --    entity's own historical average for that fiscal-month label across
  --    the fiscal years already generated above. Skips (entity, month)
  --    combinations with no history rather than inventing one from
  --    nothing.
  -- --------------------------------------------------------------------
  foreach v_dim in array v_dimensions loop
    if v_dim = 'company' then
      v_entities := array['ALL'];
    elsif v_dim = 'sales_person' then
      v_entities := v_reps;
    elsif v_dim = 'customer' then
      v_entities := v_customer_codes;
    elsif v_dim = 'item' then
      v_entities := v_item_codes;
    elsif v_dim = 'category' then
      v_entities := v_categories;
    elsif v_dim = 'branch' then
      v_entities := v_branches;
    end if;

    foreach v_entity in array v_entities loop
      foreach v_fm in array v_fiscal_months loop
        select avg(value) into v_hist_avg
        from v_dimension_monthly_sales
        where client_id = v_client_id
          and dimension = v_dim
          and entity_code = v_entity
          and fiscal_month = v_fm;

        if v_hist_avg is not null then
          insert into budget_figures (client_id, dimension, entity_code, fiscal_month, budget_value)
          values (v_client_id, v_dim, v_entity, v_fm, round((v_hist_avg * (1.05 + random() * 0.08))::numeric, 2));

          insert into sales_forecast (client_id, dimension, entity_code, fiscal_month, forecast_value, confidence)
          values (v_client_id, v_dim, v_entity, v_fm, round((v_hist_avg * (0.97 + random() * 0.1))::numeric, 2), 'full');
        end if;
      end loop;
    end loop;
  end loop;

end $$;

commit;

-- ============================================================================
-- Post-run sanity queries (safe to run manually, not part of the seed itself)
-- ============================================================================
-- select document_kind, count(*), sum(value) from sales_document_facts
--   f join clients c on c.id = f.client_id where c.code='WCSA' group by 1;
-- select dimension, count(distinct entity_code), sum(value) from
--   v_dimension_monthly_sales m join clients c on c.id=m.client_id
--   where c.code='WCSA' group by 1;
-- select * from v_dimension_performance p join clients c on c.id=p.client_id
--   where c.code='WCSA' and dimension='company' order by fiscal_year, fiscal_month;
