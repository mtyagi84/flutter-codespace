-- ============================================================
-- 019_finance_vouchers.sql
-- Finance transaction tables: voucher headers, lines, settlement,
-- cheque register, and the sequence tracker for document numbering.
--
-- Scope of first screen: CRV / BRV / CPV / BPV only.
-- Other voucher types (JV, SDN, SCN, CDN, CCN, SIV) use same tables.
--
-- Prefix conventions:
--   ril_ = lookup / config (sequence tracker)
--   rih_ = transaction header
--   rid_ = transaction detail / lines
-- ============================================================


-- ------------------------------------------------------------
-- ril_trans_no_seq
-- Tracks the running document number per (company, location, voucher type).
-- Locked with FOR UPDATE inside fn_next_trans_no to prevent duplicates
-- under concurrent users.
-- ------------------------------------------------------------
create table ril_trans_no_seq (
    client_id           uuid    not null references ric_clients(id),
    company_id          uuid    not null references ric_companies(id),
    location_id         uuid    not null references ric_locations(id),
    voucher_type_code   text    not null,
    current_seq         integer not null default 0,
    last_reset_date     date,
    updated_at          timestamptz not null default now(),
    primary key (client_id, company_id, location_id, voucher_type_code)
);

alter table ril_trans_no_seq enable row level security;
create policy "dev_allow_all_trans_no_seq" on ril_trans_no_seq for all using (true) with check (true);


-- ------------------------------------------------------------
-- rih_finance_headers
-- One row per voucher document (CRV/BRV/CPV/BPV/JV/…).
-- trans_no is assigned at first DRAFT save via fn_next_trans_no.
-- Once is_posted = true the row is permanently locked.
-- Corrections via reversal only (reversal_of_trans_no self-FK by value).
-- ------------------------------------------------------------
create table rih_finance_headers (
    id                      uuid        primary key default gen_random_uuid(),
    client_id               uuid        not null references ric_clients(id),
    company_id              uuid        not null references ric_companies(id),
    location_id             uuid        not null references ric_locations(id),
    trans_no                text        not null,
    trans_date              date        not null,
    voucher_type_code       text        not null,
    payment_mode_code       text,
    -- false = Against Invoice (single party, inv_bill_no on line)
    -- true  = On Account (multi-party allowed, settled later)
    is_on_account           boolean     not null default false,
    reference_no            text,
    reference_date          date,
    -- Populated only when payment_mode_code = 'CHEQUE'
    cheque_no               text,
    cheque_date             date,
    remarks                 text,
    is_posted               boolean     not null default false,
    posted_at               timestamptz,
    posted_by               uuid        references rim_users(id),
    -- Document number of the voucher this reverses (text FK, validated in app)
    reversal_of_trans_no    text,
    is_active               boolean     not null default true,
    is_deleted              boolean     not null default false,
    created_at              timestamptz not null default now(),
    created_by              uuid        references rim_users(id),
    updated_at              timestamptz,
    updated_by              uuid        references rim_users(id),
    constraint uq_rih_finance_headers
        unique (client_id, company_id, location_id, trans_no)
);

create index idx_rih_finance_headers_date
    on rih_finance_headers (company_id, location_id, trans_date desc);
create index idx_rih_finance_headers_type
    on rih_finance_headers (company_id, location_id, voucher_type_code, is_posted);

alter table rih_finance_headers enable row level security;
create policy "dev_allow_all_finance_headers" on rih_finance_headers for all using (true) with check (true);


-- ------------------------------------------------------------
-- rid_finance_lines
-- Multiple rows per voucher. serial_no 1 is always the cash/bank line.
-- party_amount / party_currency / party_rate stored on EVERY line
-- so the ledger report for any account needs no joins.
-- inv_bill_no / inv_bill_date / settled_amount are populated only on
-- the customer/supplier party line; NULL on revenue, VAT, discount lines.
-- ------------------------------------------------------------
create table rid_finance_lines (
    id              uuid        primary key default gen_random_uuid(),
    client_id       uuid        not null references ric_clients(id),
    company_id      uuid        not null references ric_companies(id),
    location_id     uuid        not null references ric_locations(id),
    trans_no        text        not null,
    -- 1 = Cash/Bank account (always), 2+ = counterpart accounts
    serial_no       integer     not null,
    account_id      uuid        not null references rim_accounts(id),
    trans_nature    text        not null check (trans_nature in ('DR', 'CR')),
    -- Transaction currency = currency of Cash/Bank account (locked from line 1)
    trans_amount    numeric(18,4) not null default 0,
    trans_currency  text        not null,
    -- Company base currency
    base_amount     numeric(18,4) not null default 0,
    base_rate       numeric(18,8) not null default 1,
    -- Regional / local currency
    local_amount    numeric(18,4) not null default 0,
    local_rate      numeric(18,8) not null default 1,
    -- Party / ledger currency — stored on ALL lines for ledger printing
    party_amount    numeric(18,4) not null default 0,
    party_currency  text        not null,
    party_rate      numeric(18,8) not null default 1,
    -- Invoice linkage: populated on party lines only, NULL on revenue/VAT/discount lines
    inv_bill_no     text,
    inv_bill_date   date,
    -- Running total of how much has been received/paid against this invoice line
    settled_amount  numeric(18,4) not null default 0,
    -- Editable in UI on party lines only; for On Account multi-party each has own remark
    line_remarks    text,
    is_deleted      boolean     not null default false,
    created_at      timestamptz not null default now(),
    created_by      uuid        references rim_users(id),
    updated_at      timestamptz,
    updated_by      uuid        references rim_users(id),
    constraint uq_rid_finance_lines
        unique (client_id, company_id, location_id, trans_no, serial_no),
    constraint rid_finance_lines_header_fk
        foreign key (client_id, company_id, location_id, trans_no)
        references rih_finance_headers (client_id, company_id, location_id, trans_no)
);

create index idx_rid_finance_lines_account
    on rid_finance_lines (company_id, location_id, account_id, is_deleted);
create index idx_rid_finance_lines_inv
    on rid_finance_lines (company_id, location_id, inv_bill_no)
    where inv_bill_no is not null;

alter table rid_finance_lines enable row level security;
create policy "dev_allow_all_finance_lines" on rid_finance_lines for all using (true) with check (true);


-- ------------------------------------------------------------
-- rid_invoice_bill_settlement
-- One row per payment applied against an invoice/bill.
-- settlement_no = 1st, 2nd, 3rd… payment against the same invoice.
-- was_balance = outstanding in party currency BEFORE this payment.
-- ------------------------------------------------------------
create table rid_invoice_bill_settlement (
    id                  uuid        primary key default gen_random_uuid(),
    client_id           uuid        not null references ric_clients(id),
    company_id          uuid        not null references ric_companies(id),
    location_id         uuid        not null references ric_locations(id),
    -- The payment/receipt voucher doing the settling
    trans_no            text        not null,
    trans_date          date        not null,
    voucher_type_code   text        not null,
    -- Customer or supplier account being settled
    account_id          uuid        not null references rim_accounts(id),
    -- Invoice/bill being settled
    inv_bill_no         text        not null,
    inv_bill_date       date,
    -- 1st, 2nd, 3rd… payment count against this invoice (not the line serial_no)
    settlement_no       integer     not null,
    -- Outstanding balance in party currency before this settlement
    was_balance         numeric(18,4) not null,
    -- Amount applied in party currency
    paid_amount         numeric(18,4) not null,
    -- Same in transaction currency (cash/bank account currency)
    paid_amount_trans   numeric(18,4) not null,
    is_deleted          boolean     not null default false,
    created_at          timestamptz not null default now(),
    created_by          uuid        references rim_users(id),
    updated_at          timestamptz,
    updated_by          uuid        references rim_users(id),
    constraint uq_rid_invoice_bill_settlement
        unique (client_id, company_id, location_id, account_id, inv_bill_no, settlement_no)
);

create index idx_rid_settlement_inv
    on rid_invoice_bill_settlement (company_id, location_id, inv_bill_no, account_id);

alter table rid_invoice_bill_settlement enable row level security;
create policy "dev_allow_all_invoice_settlement" on rid_invoice_bill_settlement for all using (true) with check (true);


-- ------------------------------------------------------------
-- rid_cheque_register
-- Created automatically when fn_post_finance_voucher runs on a
-- cheque-mode voucher. Status managed from separate Cheque Register screen.
-- ------------------------------------------------------------
create table rid_cheque_register (
    id                  uuid        primary key default gen_random_uuid(),
    client_id           uuid        not null references ric_clients(id),
    company_id          uuid        not null references ric_companies(id),
    location_id         uuid        not null references ric_locations(id),
    trans_no            text        not null,
    cheque_no           text        not null,
    -- Date written on the cheque (may be future — post-dated cheque)
    cheque_date         date        not null,
    bank_name           text,
    branch              text,
    cheque_status       text        not null default 'ISSUED'
                                    check (cheque_status in ('ISSUED','CLEARED','BOUNCED','CANCELLED')),
    cleared_date        date,
    bounced_date        date,
    cancellation_reason text,
    is_deleted          boolean     not null default false,
    created_at          timestamptz not null default now(),
    created_by          uuid        references rim_users(id),
    updated_at          timestamptz,
    updated_by          uuid        references rim_users(id),
    constraint rid_cheque_register_header_fk
        foreign key (client_id, company_id, location_id, trans_no)
        references rih_finance_headers (client_id, company_id, location_id, trans_no)
);

create index idx_rid_cheque_register_status
    on rid_cheque_register (company_id, location_id, cheque_status)
    where is_deleted = false;

alter table rid_cheque_register enable row level security;
create policy "dev_allow_all_cheque_register" on rid_cheque_register for all using (true) with check (true);


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_next_trans_no
-- Generates the next document number for a voucher type at a location.
-- Uses FOR UPDATE row lock on ril_trans_no_seq to prevent duplicate
-- numbers under concurrent users.
-- Format tokens resolved: {TYPE} {LOC} {YYYY} {MM} {DD} {SEQ4} {SEQ5} {SEQ6}
-- ------------------------------------------------------------
create or replace function fn_next_trans_no(
    p_client_id       uuid,
    p_company_id      uuid,
    p_location_id     uuid,
    p_voucher_type    text
)
returns text
language plpgsql
as $$
declare
    v_vt            record;
    v_loc_short     text;
    v_seq           integer;
    v_last_reset    date;
    v_today         date := current_date;
    v_should_reset  boolean := false;
    v_result        text;
begin
    -- Get voucher type config: prefer client-specific over system
    select vt.reset_frequency, vt.trans_no_format
    into v_vt
    from rim_voucher_types vt
    where vt.voucher_type_code = p_voucher_type
      and vt.is_active  = true
      and vt.is_deleted = false
      and (vt.is_system = true
           or (vt.client_id = p_client_id and vt.company_id = p_company_id))
    order by vt.is_system asc   -- false (client-specific) sorts before true (system)
    limit 1;

    if not found then
        raise exception 'Voucher type % not found or inactive', p_voucher_type;
    end if;

    -- Get location short code for {LOC} token
    select coalesce(location_short, left(id::text, 3)) into v_loc_short
    from ric_locations where id = p_location_id;

    -- Ensure sequence row exists, then lock it
    insert into ril_trans_no_seq (client_id, company_id, location_id, voucher_type_code, current_seq, last_reset_date)
    values (p_client_id, p_company_id, p_location_id, p_voucher_type, 0, v_today)
    on conflict (client_id, company_id, location_id, voucher_type_code) do nothing;

    select current_seq, last_reset_date
    into v_seq, v_last_reset
    from ril_trans_no_seq
    where client_id = p_client_id and company_id = p_company_id
      and location_id = p_location_id and voucher_type_code = p_voucher_type
    for update;

    -- Determine if reset is due
    v_should_reset := case v_vt.reset_frequency
        when 'DAILY'   then v_last_reset is null or v_last_reset < v_today
        when 'MONTHLY' then v_last_reset is null
                         or to_char(v_last_reset, 'YYYY-MM') < to_char(v_today, 'YYYY-MM')
        when 'YEARLY'  then v_last_reset is null
                         or to_char(v_last_reset, 'YYYY') < to_char(v_today, 'YYYY')
        else false
    end;

    v_seq := case when v_should_reset then 1 else v_seq + 1 end;

    update ril_trans_no_seq set
        current_seq     = v_seq,
        last_reset_date = v_today,
        updated_at      = now()
    where client_id = p_client_id and company_id = p_company_id
      and location_id = p_location_id and voucher_type_code = p_voucher_type;

    -- Resolve format template tokens
    v_result := v_vt.trans_no_format;
    v_result := replace(v_result, '{TYPE}', p_voucher_type);
    v_result := replace(v_result, '{LOC}',  upper(coalesce(v_loc_short, '')));
    v_result := replace(v_result, '{YYYY}', to_char(v_today, 'YYYY'));
    v_result := replace(v_result, '{MM}',   to_char(v_today, 'MM'));
    v_result := replace(v_result, '{DD}',   to_char(v_today, 'DD'));
    v_result := replace(v_result, '{SEQ6}', lpad(v_seq::text, 6, '0'));
    v_result := replace(v_result, '{SEQ5}', lpad(v_seq::text, 5, '0'));
    v_result := replace(v_result, '{SEQ4}', lpad(v_seq::text, 4, '0'));

    return v_result;
end;
$$;


-- ------------------------------------------------------------
-- fn_save_finance_voucher
-- Atomically saves (or updates a draft) voucher header + lines.
-- Generates trans_no on first save when p_header->>'trans_no' is null/empty.
-- Blocks if the voucher is already posted.
-- Lines are hard-deleted and re-inserted on each save (drafts only —
-- no audit value for unposted line revisions).
-- Returns the trans_no.
-- ------------------------------------------------------------
create or replace function fn_save_finance_voucher(
    p_header    jsonb,
    p_lines     jsonb,
    p_user_id   uuid
)
returns text
language plpgsql
as $$
declare
    v_client_id     uuid;
    v_company_id    uuid;
    v_location_id   uuid;
    v_trans_no      text;
    v_is_new        boolean;
    v_line          jsonb;
begin
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_trans_no    := nullif(trim(p_header->>'trans_no'), '');
    v_is_new      := v_trans_no is null;

    if v_is_new then
        v_trans_no := fn_next_trans_no(
            v_client_id, v_company_id, v_location_id,
            p_header->>'voucher_type_code'
        );
    else
        if exists (
            select 1 from rih_finance_headers
            where client_id   = v_client_id
              and company_id  = v_company_id
              and location_id = v_location_id
              and trans_no    = v_trans_no
              and is_posted   = true
        ) then
            raise exception 'Voucher % is already posted and cannot be modified. Use Reversal to correct.', v_trans_no;
        end if;
    end if;

    -- Upsert header
    insert into rih_finance_headers (
        client_id, company_id, location_id, trans_no, trans_date,
        voucher_type_code, payment_mode_code, is_on_account,
        reference_no, reference_date,
        cheque_no, cheque_date,
        remarks, created_by, updated_by
    ) values (
        v_client_id, v_company_id, v_location_id,
        v_trans_no,
        (p_header->>'trans_date')::date,
        p_header->>'voucher_type_code',
        nullif(p_header->>'payment_mode_code', ''),
        coalesce((p_header->>'is_on_account')::boolean, false),
        nullif(p_header->>'reference_no', ''),
        (nullif(p_header->>'reference_date', ''))::date,
        nullif(p_header->>'cheque_no', ''),
        (nullif(p_header->>'cheque_date', ''))::date,
        nullif(p_header->>'remarks', ''),
        p_user_id, p_user_id
    )
    on conflict (client_id, company_id, location_id, trans_no) do update set
        trans_date        = excluded.trans_date,
        payment_mode_code = excluded.payment_mode_code,
        is_on_account     = excluded.is_on_account,
        reference_no      = excluded.reference_no,
        reference_date    = excluded.reference_date,
        cheque_no         = excluded.cheque_no,
        cheque_date       = excluded.cheque_date,
        remarks           = excluded.remarks,
        updated_at        = now(),
        updated_by        = excluded.updated_by;

    -- Remove old draft lines then re-insert (drafts carry no audit requirement)
    delete from rid_finance_lines
    where client_id   = v_client_id
      and company_id  = v_company_id
      and location_id = v_location_id
      and trans_no    = v_trans_no;

    -- Insert each line from the JSON array
    for v_line in select * from jsonb_array_elements(p_lines)
    loop
        insert into rid_finance_lines (
            client_id, company_id, location_id, trans_no,
            serial_no, account_id, trans_nature,
            trans_amount, trans_currency,
            base_amount,  base_rate,
            local_amount, local_rate,
            party_amount, party_currency, party_rate,
            inv_bill_no, inv_bill_date,
            line_remarks, created_by, updated_by
        ) values (
            v_client_id, v_company_id, v_location_id, v_trans_no,
            (v_line->>'serial_no')::integer,
            (v_line->>'account_id')::uuid,
            v_line->>'trans_nature',
            coalesce((v_line->>'trans_amount')::numeric,  0),
            v_line->>'trans_currency',
            coalesce((v_line->>'base_amount')::numeric,   0),
            coalesce((v_line->>'base_rate')::numeric,     1),
            coalesce((v_line->>'local_amount')::numeric,  0),
            coalesce((v_line->>'local_rate')::numeric,    1),
            coalesce((v_line->>'party_amount')::numeric,  0),
            v_line->>'party_currency',
            coalesce((v_line->>'party_rate')::numeric,    1),
            nullif(v_line->>'inv_bill_no', ''),
            (nullif(v_line->>'inv_bill_date', ''))::date,
            nullif(v_line->>'line_remarks', ''),
            p_user_id, p_user_id
        );
    end loop;

    return v_trans_no;
end;
$$;


-- ------------------------------------------------------------
-- fn_post_finance_voucher
-- Posts a saved draft: marks it permanent, inserts cheque register
-- row (if cheque payment), and creates settlement records (if Against Invoice).
-- Validates: not already posted, DR total = CR total (within 0.01 rounding).
-- ------------------------------------------------------------
create or replace function fn_post_finance_voucher(
    p_client_id   uuid,
    p_company_id  uuid,
    p_location_id uuid,
    p_trans_no    text,
    p_posted_by   uuid
)
returns void
language plpgsql
as $$
declare
    v_header        rih_finance_headers%rowtype;
    v_line          rid_finance_lines%rowtype;
    v_imbalance     numeric;
    v_was_balance   numeric;
    v_settle_no     integer;
begin
    -- Lock the header row
    select * into v_header from rih_finance_headers
    where client_id   = p_client_id
      and company_id  = p_company_id
      and location_id = p_location_id
      and trans_no    = p_trans_no
    for update;

    if not found then
        raise exception 'Voucher % not found', p_trans_no;
    end if;

    if v_header.is_posted then
        raise exception 'Voucher % is already posted', p_trans_no;
    end if;

    -- Validate DR = CR (allow 0.01 rounding tolerance)
    select abs(sum(
        case when trans_nature = 'DR' then trans_amount else -trans_amount end
    ))
    into v_imbalance
    from rid_finance_lines
    where client_id   = p_client_id
      and company_id  = p_company_id
      and location_id = p_location_id
      and trans_no    = p_trans_no
      and is_deleted  = false;

    if coalesce(v_imbalance, 0) > 0.01 then
        raise exception 'Voucher % is not balanced — DR and CR totals do not match (difference: %)',
            p_trans_no, v_imbalance;
    end if;

    -- Mark as posted
    update rih_finance_headers set
        is_posted  = true,
        posted_at  = now(),
        posted_by  = p_posted_by,
        updated_at = now(),
        updated_by = p_posted_by
    where client_id   = p_client_id
      and company_id  = p_company_id
      and location_id = p_location_id
      and trans_no    = p_trans_no;

    -- Cheque register: insert if cheque payment mode
    if v_header.cheque_no is not null then
        insert into rid_cheque_register (
            client_id, company_id, location_id, trans_no,
            cheque_no, cheque_date,
            cheque_status, created_by, updated_by
        ) values (
            p_client_id, p_company_id, p_location_id, p_trans_no,
            v_header.cheque_no, v_header.cheque_date,
            'ISSUED', p_posted_by, p_posted_by
        )
        on conflict do nothing;
    end if;

    -- Settlement: only for Against Invoice vouchers
    if not v_header.is_on_account then
        for v_line in
            select * from rid_finance_lines
            where client_id   = p_client_id
              and company_id  = p_company_id
              and location_id = p_location_id
              and trans_no    = p_trans_no
              and is_deleted  = false
              and inv_bill_no is not null
        loop
            -- Outstanding balance on the original invoice party line
            select coalesce(party_amount - settled_amount, 0)
            into v_was_balance
            from rid_finance_lines
            where client_id   = p_client_id
              and company_id  = p_company_id
              and location_id = p_location_id
              and trans_no    = v_line.inv_bill_no
              and account_id  = v_line.account_id
              and is_deleted  = false
            limit 1;

            -- Next settlement sequence for this invoice
            select coalesce(max(settlement_no), 0) + 1
            into v_settle_no
            from rid_invoice_bill_settlement
            where client_id   = p_client_id
              and company_id  = p_company_id
              and location_id = p_location_id
              and account_id  = v_line.account_id
              and inv_bill_no = v_line.inv_bill_no
              and is_deleted  = false;

            insert into rid_invoice_bill_settlement (
                client_id, company_id, location_id,
                trans_no, trans_date, voucher_type_code,
                account_id, inv_bill_no, inv_bill_date,
                settlement_no, was_balance, paid_amount, paid_amount_trans,
                created_by, updated_by
            ) values (
                p_client_id, p_company_id, p_location_id,
                p_trans_no, v_header.trans_date, v_header.voucher_type_code,
                v_line.account_id, v_line.inv_bill_no, v_line.inv_bill_date,
                v_settle_no,
                coalesce(v_was_balance, 0),
                v_line.party_amount,
                v_line.trans_amount,
                p_posted_by, p_posted_by
            );

            -- Update settled_amount on the original invoice finance line
            -- (safe update — no error if original line not yet in this DB, e.g. before sales module built)
            update rid_finance_lines set
                settled_amount = settled_amount + v_line.party_amount,
                updated_at     = now(),
                updated_by     = p_posted_by
            where client_id   = p_client_id
              and company_id  = p_company_id
              and location_id = p_location_id
              and trans_no    = v_line.inv_bill_no
              and account_id  = v_line.account_id
              and is_deleted  = false;
        end loop;
    end if;
end;
$$;
