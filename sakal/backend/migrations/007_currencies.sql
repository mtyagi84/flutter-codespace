-- ============================================================
-- 007_currencies.sql
-- Currency master table + auto-seed trigger
-- Prefix: rim_ (Rigevedam Innovations + Master data)
-- country_code: ISO 3166-1 alpha-2 (future FK to rim_countries)
-- ============================================================

CREATE TABLE rim_currencies (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         uuid        NOT NULL REFERENCES ric_clients(id),
    company_id        uuid        NOT NULL REFERENCES ric_companies(id),
    currency_id       text        NOT NULL,   -- ISO 4217 code: USD, CDF, ZMW
    currency_name     text        NOT NULL,
    currency_notation text        NOT NULL,   -- symbol: $, FC, K
    currency_coin     text,                   -- sub-unit name: Cent, Centime — NULL if none
    country_code      text,                   -- ISO 3166 alpha-2 — future FK rim_countries
    is_active         boolean     NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    updated_at        timestamptz,
    updated_by        uuid,
    UNIQUE (client_id, company_id, currency_id)
);

CREATE INDEX ON rim_currencies (client_id, company_id);
CREATE INDEX ON rim_currencies (currency_id);

ALTER TABLE rim_currencies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dev_allow_all_currencies" ON rim_currencies FOR ALL USING (true) WITH CHECK (true);


-- ============================================================
-- fn_seed_company_currencies
-- Fires on INSERT into ric_companies.
-- Seeds all ~155 ISO 4217 currencies as inactive, then activates
-- whichever match the company's base_currency + local_currency.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_company_currencies()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO rim_currencies
        (client_id, company_id, currency_id, currency_name, currency_notation, currency_coin, country_code, is_active)
    VALUES
        -- A
        (NEW.client_id, NEW.id, 'AED', 'UAE Dirham',                          'AED',  'Fils',           'AE', false),
        (NEW.client_id, NEW.id, 'AFN', 'Afghan Afghani',                      'Af',   'Pul',            'AF', false),
        (NEW.client_id, NEW.id, 'ALL', 'Albanian Lek',                        'L',    'Qindarkë',       'AL', false),
        (NEW.client_id, NEW.id, 'AMD', 'Armenian Dram',                       'AMD',  'Luma',           'AM', false),
        (NEW.client_id, NEW.id, 'ANG', 'Netherlands Antillean Guilder',       'ƒ',    'Cent',           'CW', false),
        (NEW.client_id, NEW.id, 'AOA', 'Angolan Kwanza',                      'Kz',   'Cêntimo',        'AO', false),
        (NEW.client_id, NEW.id, 'ARS', 'Argentine Peso',                      '$',    'Centavo',        'AR', false),
        (NEW.client_id, NEW.id, 'AUD', 'Australian Dollar',                   'A$',   'Cent',           'AU', false),
        (NEW.client_id, NEW.id, 'AWG', 'Aruban Florin',                       'ƒ',    'Cent',           'AW', false),
        (NEW.client_id, NEW.id, 'AZN', 'Azerbaijani Manat',                   '₼',    'Qəpik',          'AZ', false),
        -- B
        (NEW.client_id, NEW.id, 'BAM', 'Bosnia-Herzegovina Convertible Mark', 'KM',   'Fening',         'BA', false),
        (NEW.client_id, NEW.id, 'BBD', 'Barbadian Dollar',                    '$',    'Cent',           'BB', false),
        (NEW.client_id, NEW.id, 'BDT', 'Bangladeshi Taka',                    '৳',    'Paisa',          'BD', false),
        (NEW.client_id, NEW.id, 'BGN', 'Bulgarian Lev',                       'лв',   'Stotinka',       'BG', false),
        (NEW.client_id, NEW.id, 'BHD', 'Bahraini Dinar',                      'BD',   'Fils',           'BH', false),
        (NEW.client_id, NEW.id, 'BIF', 'Burundian Franc',                     'Fr',   NULL,             'BI', false),
        (NEW.client_id, NEW.id, 'BMD', 'Bermudian Dollar',                    '$',    'Cent',           'BM', false),
        (NEW.client_id, NEW.id, 'BND', 'Brunei Dollar',                       '$',    'Sen',            'BN', false),
        (NEW.client_id, NEW.id, 'BOB', 'Bolivian Boliviano',                  'Bs',   'Centavo',        'BO', false),
        (NEW.client_id, NEW.id, 'BRL', 'Brazilian Real',                      'R$',   'Centavo',        'BR', false),
        (NEW.client_id, NEW.id, 'BSD', 'Bahamian Dollar',                     '$',    'Cent',           'BS', false),
        (NEW.client_id, NEW.id, 'BTN', 'Bhutanese Ngultrum',                  'Nu',   'Chetrum',        'BT', false),
        (NEW.client_id, NEW.id, 'BWP', 'Botswana Pula',                       'P',    'Thebe',          'BW', false),
        (NEW.client_id, NEW.id, 'BYN', 'Belarusian Ruble',                    'Br',   'Kopek',          'BY', false),
        (NEW.client_id, NEW.id, 'BZD', 'Belize Dollar',                       '$',    'Cent',           'BZ', false),
        -- C
        (NEW.client_id, NEW.id, 'CAD', 'Canadian Dollar',                     'CA$',  'Cent',           'CA', false),
        (NEW.client_id, NEW.id, 'CDF', 'Congolese Franc',                     'FC',   'Centime',        'CD', false),
        (NEW.client_id, NEW.id, 'CHF', 'Swiss Franc',                         'Fr',   'Rappen',         'CH', false),
        (NEW.client_id, NEW.id, 'CLP', 'Chilean Peso',                        '$',    'Centavo',        'CL', false),
        (NEW.client_id, NEW.id, 'CNY', 'Chinese Yuan',                        '¥',    'Fen',            'CN', false),
        (NEW.client_id, NEW.id, 'COP', 'Colombian Peso',                      '$',    'Centavo',        'CO', false),
        (NEW.client_id, NEW.id, 'CRC', 'Costa Rican Colón',                   '₡',    'Céntimo',        'CR', false),
        (NEW.client_id, NEW.id, 'CUP', 'Cuban Peso',                          '$',    'Centavo',        'CU', false),
        (NEW.client_id, NEW.id, 'CVE', 'Cape Verdean Escudo',                 'Esc',  'Centavo',        'CV', false),
        (NEW.client_id, NEW.id, 'CZK', 'Czech Koruna',                        'Kč',   'Haléř',          'CZ', false),
        -- D
        (NEW.client_id, NEW.id, 'DJF', 'Djiboutian Franc',                    'Fr',   NULL,             'DJ', false),
        (NEW.client_id, NEW.id, 'DKK', 'Danish Krone',                        'kr',   'Øre',            'DK', false),
        (NEW.client_id, NEW.id, 'DOP', 'Dominican Peso',                      '$',    'Centavo',        'DO', false),
        (NEW.client_id, NEW.id, 'DZD', 'Algerian Dinar',                      'DA',   'Centime',        'DZ', false),
        -- E
        (NEW.client_id, NEW.id, 'EGP', 'Egyptian Pound',                      '£',    'Piastre',        'EG', false),
        (NEW.client_id, NEW.id, 'ERN', 'Eritrean Nakfa',                       'Nfk',  'Cent',           'ER', false),
        (NEW.client_id, NEW.id, 'ETB', 'Ethiopian Birr',                       'Br',   'Santim',         'ET', false),
        (NEW.client_id, NEW.id, 'EUR', 'Euro',                                 '€',    'Cent',           'EU', false),
        -- F
        (NEW.client_id, NEW.id, 'FJD', 'Fijian Dollar',                        'FJ$',  'Cent',           'FJ', false),
        (NEW.client_id, NEW.id, 'FKP', 'Falkland Islands Pound',               '£',    'Penny',          'FK', false),
        -- G
        (NEW.client_id, NEW.id, 'GBP', 'British Pound Sterling',               '£',    'Penny',          'GB', false),
        (NEW.client_id, NEW.id, 'GEL', 'Georgian Lari',                        '₾',    'Tetri',          'GE', false),
        (NEW.client_id, NEW.id, 'GHS', 'Ghanaian Cedi',                        '₵',    'Pesewa',         'GH', false),
        (NEW.client_id, NEW.id, 'GIP', 'Gibraltar Pound',                      '£',    'Penny',          'GI', false),
        (NEW.client_id, NEW.id, 'GMD', 'Gambian Dalasi',                       'D',    'Butut',          'GM', false),
        (NEW.client_id, NEW.id, 'GNF', 'Guinean Franc',                        'Fr',   NULL,             'GN', false),
        (NEW.client_id, NEW.id, 'GTQ', 'Guatemalan Quetzal',                   'Q',    'Centavo',        'GT', false),
        (NEW.client_id, NEW.id, 'GYD', 'Guyanese Dollar',                      '$',    'Cent',           'GY', false),
        -- H
        (NEW.client_id, NEW.id, 'HKD', 'Hong Kong Dollar',                     'HK$',  'Cent',           'HK', false),
        (NEW.client_id, NEW.id, 'HNL', 'Honduran Lempira',                     'L',    'Centavo',        'HN', false),
        (NEW.client_id, NEW.id, 'HTG', 'Haitian Gourde',                       'G',    'Centime',        'HT', false),
        (NEW.client_id, NEW.id, 'HUF', 'Hungarian Forint',                     'Ft',   'Fillér',         'HU', false),
        -- I
        (NEW.client_id, NEW.id, 'IDR', 'Indonesian Rupiah',                    'Rp',   'Sen',            'ID', false),
        (NEW.client_id, NEW.id, 'ILS', 'Israeli New Shekel',                   '₪',    'Agora',          'IL', false),
        (NEW.client_id, NEW.id, 'INR', 'Indian Rupee',                         '₹',    'Paisa',          'IN', false),
        (NEW.client_id, NEW.id, 'IQD', 'Iraqi Dinar',                          'IQD',  'Fils',           'IQ', false),
        (NEW.client_id, NEW.id, 'IRR', 'Iranian Rial',                         'Rls',  'Dinar',          'IR', false),
        (NEW.client_id, NEW.id, 'ISK', 'Icelandic Króna',                      'kr',   'Eyrir',          'IS', false),
        -- J
        (NEW.client_id, NEW.id, 'JMD', 'Jamaican Dollar',                      '$',    'Cent',           'JM', false),
        (NEW.client_id, NEW.id, 'JOD', 'Jordanian Dinar',                      'JD',   'Fils',           'JO', false),
        (NEW.client_id, NEW.id, 'JPY', 'Japanese Yen',                         '¥',    NULL,             'JP', false),
        -- K
        (NEW.client_id, NEW.id, 'KES', 'Kenyan Shilling',                      'KSh',  'Cent',           'KE', false),
        (NEW.client_id, NEW.id, 'KGS', 'Kyrgyzstani Som',                      'с',    'Tyiyn',          'KG', false),
        (NEW.client_id, NEW.id, 'KHR', 'Cambodian Riel',                       '៛',    'Sen',            'KH', false),
        (NEW.client_id, NEW.id, 'KMF', 'Comorian Franc',                       'Fr',   NULL,             'KM', false),
        (NEW.client_id, NEW.id, 'KPW', 'North Korean Won',                     '₩',    'Chon',           'KP', false),
        (NEW.client_id, NEW.id, 'KRW', 'South Korean Won',                     '₩',    NULL,             'KR', false),
        (NEW.client_id, NEW.id, 'KWD', 'Kuwaiti Dinar',                        'KD',   'Fils',           'KW', false),
        (NEW.client_id, NEW.id, 'KYD', 'Cayman Islands Dollar',                '$',    'Cent',           'KY', false),
        (NEW.client_id, NEW.id, 'KZT', 'Kazakhstani Tenge',                    '₸',    'Tiyin',          'KZ', false),
        -- L
        (NEW.client_id, NEW.id, 'LAK', 'Lao Kip',                              '₭',    'Att',            'LA', false),
        (NEW.client_id, NEW.id, 'LBP', 'Lebanese Pound',                       'LL',   'Piastre',        'LB', false),
        (NEW.client_id, NEW.id, 'LKR', 'Sri Lankan Rupee',                     'Rs',   'Cent',           'LK', false),
        (NEW.client_id, NEW.id, 'LRD', 'Liberian Dollar',                      '$',    'Cent',           'LR', false),
        (NEW.client_id, NEW.id, 'LSL', 'Lesotho Loti',                         'L',    'Sente',          'LS', false),
        (NEW.client_id, NEW.id, 'LYD', 'Libyan Dinar',                         'LD',   'Dirham',         'LY', false),
        -- M
        (NEW.client_id, NEW.id, 'MAD', 'Moroccan Dirham',                      'MAD',  'Centime',        'MA', false),
        (NEW.client_id, NEW.id, 'MDL', 'Moldovan Leu',                         'L',    'Ban',            'MD', false),
        (NEW.client_id, NEW.id, 'MGA', 'Malagasy Ariary',                      'Ar',   NULL,             'MG', false),
        (NEW.client_id, NEW.id, 'MKD', 'Macedonian Denar',                     'ден',  'Deni',           'MK', false),
        (NEW.client_id, NEW.id, 'MMK', 'Myanmar Kyat',                         'K',    'Pya',            'MM', false),
        (NEW.client_id, NEW.id, 'MNT', 'Mongolian Tögrög',                     '₮',    'Möngö',          'MN', false),
        (NEW.client_id, NEW.id, 'MOP', 'Macanese Pataca',                      'P',    'Avo',            'MO', false),
        (NEW.client_id, NEW.id, 'MRU', 'Mauritanian Ouguiya',                  'UM',   'Khoum',          'MR', false),
        (NEW.client_id, NEW.id, 'MUR', 'Mauritian Rupee',                      'Rs',   'Cent',           'MU', false),
        (NEW.client_id, NEW.id, 'MVR', 'Maldivian Rufiyaa',                    'Rf',   'Laari',          'MV', false),
        (NEW.client_id, NEW.id, 'MWK', 'Malawian Kwacha',                      'MK',   'Tambala',        'MW', false),
        (NEW.client_id, NEW.id, 'MXN', 'Mexican Peso',                         '$',    'Centavo',        'MX', false),
        (NEW.client_id, NEW.id, 'MYR', 'Malaysian Ringgit',                    'RM',   'Sen',            'MY', false),
        (NEW.client_id, NEW.id, 'MZN', 'Mozambican Metical',                   'MT',   'Centavo',        'MZ', false),
        -- N
        (NEW.client_id, NEW.id, 'NAD', 'Namibian Dollar',                      '$',    'Cent',           'NA', false),
        (NEW.client_id, NEW.id, 'NGN', 'Nigerian Naira',                       '₦',    'Kobo',           'NG', false),
        (NEW.client_id, NEW.id, 'NIO', 'Nicaraguan Córdoba',                   'C$',   'Centavo',        'NI', false),
        (NEW.client_id, NEW.id, 'NOK', 'Norwegian Krone',                      'kr',   'Øre',            'NO', false),
        (NEW.client_id, NEW.id, 'NPR', 'Nepalese Rupee',                       'Rs',   'Paisa',          'NP', false),
        (NEW.client_id, NEW.id, 'NZD', 'New Zealand Dollar',                   'NZ$',  'Cent',           'NZ', false),
        -- O
        (NEW.client_id, NEW.id, 'OMR', 'Omani Rial',                           'OMR',  'Baisa',          'OM', false),
        -- P
        (NEW.client_id, NEW.id, 'PAB', 'Panamanian Balboa',                    'B/.',  'Centésimo',      'PA', false),
        (NEW.client_id, NEW.id, 'PEN', 'Peruvian Sol',                         'S/',   'Céntimo',        'PE', false),
        (NEW.client_id, NEW.id, 'PGK', 'Papua New Guinean Kina',               'K',    'Toea',           'PG', false),
        (NEW.client_id, NEW.id, 'PHP', 'Philippine Peso',                      '₱',    'Centavo',        'PH', false),
        (NEW.client_id, NEW.id, 'PKR', 'Pakistani Rupee',                      'Rs',   'Paisa',          'PK', false),
        (NEW.client_id, NEW.id, 'PLN', 'Polish Zloty',                         'zł',   'Grosz',          'PL', false),
        (NEW.client_id, NEW.id, 'PYG', 'Paraguayan Guaraní',                   '₲',    NULL,             'PY', false),
        -- Q
        (NEW.client_id, NEW.id, 'QAR', 'Qatari Riyal',                         'QR',   'Dirham',         'QA', false),
        -- R
        (NEW.client_id, NEW.id, 'RON', 'Romanian Leu',                         'lei',  'Ban',            'RO', false),
        (NEW.client_id, NEW.id, 'RSD', 'Serbian Dinar',                        'din',  'Para',           'RS', false),
        (NEW.client_id, NEW.id, 'RUB', 'Russian Ruble',                        '₽',    'Kopek',          'RU', false),
        (NEW.client_id, NEW.id, 'RWF', 'Rwandan Franc',                        'Fr',   NULL,             'RW', false),
        -- S
        (NEW.client_id, NEW.id, 'SAR', 'Saudi Riyal',                          'SR',   'Hallallah',      'SA', false),
        (NEW.client_id, NEW.id, 'SBD', 'Solomon Islands Dollar',               'SI$',  'Cent',           'SB', false),
        (NEW.client_id, NEW.id, 'SCR', 'Seychellois Rupee',                    'Rs',   'Cent',           'SC', false),
        (NEW.client_id, NEW.id, 'SDG', 'Sudanese Pound',                       '£',    'Piastre',        'SD', false),
        (NEW.client_id, NEW.id, 'SEK', 'Swedish Krona',                        'kr',   'Öre',            'SE', false),
        (NEW.client_id, NEW.id, 'SGD', 'Singapore Dollar',                     'S$',   'Cent',           'SG', false),
        (NEW.client_id, NEW.id, 'SHP', 'Saint Helena Pound',                   '£',    'Penny',          'SH', false),
        (NEW.client_id, NEW.id, 'SLE', 'Sierra Leonean Leone',                 'Le',   'Cent',           'SL', false),
        (NEW.client_id, NEW.id, 'SOS', 'Somali Shilling',                      'Sh',   'Cent',           'SO', false),
        (NEW.client_id, NEW.id, 'SRD', 'Surinamese Dollar',                    '$',    'Cent',           'SR', false),
        (NEW.client_id, NEW.id, 'SSP', 'South Sudanese Pound',                 '£',    'Piastre',        'SS', false),
        (NEW.client_id, NEW.id, 'STN', 'Sao Tome and Principe Dobra',          'Db',   'Centimo',        'ST', false),
        (NEW.client_id, NEW.id, 'SVC', 'Salvadoran Colon',                     '₡',    'Centavo',        'SV', false),
        (NEW.client_id, NEW.id, 'SYP', 'Syrian Pound',                         '£',    'Piastre',        'SY', false),
        (NEW.client_id, NEW.id, 'SZL', 'Swazi Lilangeni',                      'L',    'Cent',           'SZ', false),
        -- T
        (NEW.client_id, NEW.id, 'THB', 'Thai Baht',                            '฿',    'Satang',         'TH', false),
        (NEW.client_id, NEW.id, 'TJS', 'Tajikistani Somoni',                   'SM',   'Diram',          'TJ', false),
        (NEW.client_id, NEW.id, 'TMT', 'Turkmenistani Manat',                  'T',    'Tennesi',        'TM', false),
        (NEW.client_id, NEW.id, 'TND', 'Tunisian Dinar',                       'DT',   'Millime',        'TN', false),
        (NEW.client_id, NEW.id, 'TOP', 'Tongan Paanga',                        'T$',   'Seniti',         'TO', false),
        (NEW.client_id, NEW.id, 'TRY', 'Turkish Lira',                         '₺',    'Kuruş',          'TR', false),
        (NEW.client_id, NEW.id, 'TTD', 'Trinidad and Tobago Dollar',           'TT$',  'Cent',           'TT', false),
        (NEW.client_id, NEW.id, 'TWD', 'New Taiwan Dollar',                    'NT$',  'Cent',           'TW', false),
        (NEW.client_id, NEW.id, 'TZS', 'Tanzanian Shilling',                   'Sh',   'Cent',           'TZ', false),
        -- U
        (NEW.client_id, NEW.id, 'UAH', 'Ukrainian Hryvnia',                    '₴',    'Kopiyka',        'UA', false),
        (NEW.client_id, NEW.id, 'UGX', 'Ugandan Shilling',                     'Sh',   NULL,             'UG', false),
        (NEW.client_id, NEW.id, 'USD', 'US Dollar',                            '$',    'Cent',           'US', false),
        (NEW.client_id, NEW.id, 'UYU', 'Uruguayan Peso',                       '$',    'Centésimo',      'UY', false),
        (NEW.client_id, NEW.id, 'UZS', 'Uzbekistani Som',                      'UZS',  'Tiyin',          'UZ', false),
        -- V
        (NEW.client_id, NEW.id, 'VES', 'Venezuelan Bolivar Soberano',          'Bs.S', 'Centimo',        'VE', false),
        (NEW.client_id, NEW.id, 'VND', 'Vietnamese Dong',                      '₫',    NULL,             'VN', false),
        (NEW.client_id, NEW.id, 'VUV', 'Vanuatu Vatu',                         'Vt',   NULL,             'VU', false),
        -- W
        (NEW.client_id, NEW.id, 'WST', 'Samoan Tala',                          'T',    'Sene',           'WS', false),
        -- X (regional)
        (NEW.client_id, NEW.id, 'XAF', 'Central African CFA Franc',            'Fr',   'Centime',        'CM', false),
        (NEW.client_id, NEW.id, 'XCD', 'East Caribbean Dollar',                '$',    'Cent',           'AG', false),
        (NEW.client_id, NEW.id, 'XOF', 'West African CFA Franc',               'Fr',   'Centime',        'SN', false),
        (NEW.client_id, NEW.id, 'XPF', 'CFP Franc',                            'Fr',   'Centime',        'PF', false),
        -- Y
        (NEW.client_id, NEW.id, 'YER', 'Yemeni Rial',                          'YR',   'Fils',           'YE', false),
        -- Z
        (NEW.client_id, NEW.id, 'ZAR', 'South African Rand',                   'R',    'Cent',           'ZA', false),
        (NEW.client_id, NEW.id, 'ZMW', 'Zambian Kwacha',                       'K',    'Ngwee',          'ZM', false),
        (NEW.client_id, NEW.id, 'ZWG', 'Zimbabwe Gold',                        'ZiG',  'Cent',           'ZW', false)
    ON CONFLICT (client_id, company_id, currency_id) DO NOTHING;

    -- Activate base currency
    IF NEW.base_currency IS NOT NULL THEN
        UPDATE rim_currencies
        SET is_active = true
        WHERE client_id = NEW.client_id
          AND company_id = NEW.id
          AND currency_id = NEW.base_currency;
    END IF;

    -- Activate local currency (if different from base)
    IF NEW.local_currency IS NOT NULL AND NEW.local_currency <> COALESCE(NEW.base_currency, '') THEN
        UPDATE rim_currencies
        SET is_active = true
        WHERE client_id = NEW.client_id
          AND company_id = NEW.id
          AND currency_id = NEW.local_currency;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_seed_company_currencies
    AFTER INSERT ON ric_companies
    FOR EACH ROW
    EXECUTE FUNCTION fn_seed_company_currencies();


-- ============================================================
-- fn_activate_company_currencies
-- Fires on UPDATE of ric_companies.
-- When base_currency or local_currency changes, auto-activates
-- the new currency. Never deactivates — user controls that.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_activate_company_currencies()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.base_currency IS DISTINCT FROM NEW.base_currency
       AND NEW.base_currency IS NOT NULL THEN
        UPDATE rim_currencies
        SET is_active = true, updated_at = now()
        WHERE client_id = NEW.client_id
          AND company_id = NEW.id
          AND currency_id = NEW.base_currency;
    END IF;

    IF OLD.local_currency IS DISTINCT FROM NEW.local_currency
       AND NEW.local_currency IS NOT NULL THEN
        UPDATE rim_currencies
        SET is_active = true, updated_at = now()
        WHERE client_id = NEW.client_id
          AND company_id = NEW.id
          AND currency_id = NEW.local_currency;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activate_company_currencies
    AFTER UPDATE ON ric_companies
    FOR EACH ROW
    EXECUTE FUNCTION fn_activate_company_currencies();
