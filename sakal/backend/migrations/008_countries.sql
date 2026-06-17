-- ============================================================
-- 008_countries.sql
-- Country master table + auto-seed trigger (~200 countries)
-- Prefix: rim_ (Rigevedam Innovations + Master data)
-- country_code      : ISO 3166-1 alpha-2
-- country_code_3    : ISO 3166-1 alpha-3
-- dial_code         : ITU-T E.164 prefix
-- default_currency_id: ISO 4217 code — FK to rim_currencies.currency_id
-- region            : Africa | Americas | Asia | Europe | Oceania
-- ============================================================

CREATE TABLE rim_countries (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            uuid        NOT NULL REFERENCES ric_clients(id),
    company_id           uuid        NOT NULL REFERENCES ric_companies(id),
    country_code         text        NOT NULL,
    country_code_3       text        NOT NULL,
    country_name         text        NOT NULL,
    dial_code            text,
    region               text,
    default_currency_id  text,
    is_active            boolean     NOT NULL DEFAULT false,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid,
    updated_at           timestamptz,
    updated_by           uuid,
    UNIQUE (client_id, company_id, country_code)
);

CREATE INDEX ON rim_countries (client_id, company_id);
CREATE INDEX ON rim_countries (country_code);
CREATE INDEX ON rim_countries (region);

ALTER TABLE rim_countries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dev_allow_all_countries" ON rim_countries FOR ALL USING (true) WITH CHECK (true);


-- ============================================================
-- fn_seed_company_countries
-- Fires on INSERT into ric_companies.
-- Seeds all ~200 ISO 3166-1 countries as inactive.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_company_countries()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO rim_countries
        (client_id, company_id, country_code, country_code_3, country_name, dial_code, region, default_currency_id, is_active)
    VALUES
        -- ── Africa ────────────────────────────────────────────────────────────
        (NEW.client_id, NEW.id, 'DZ', 'DZA', 'Algeria',                          '+213',  'Africa',   'DZD', false),
        (NEW.client_id, NEW.id, 'AO', 'AGO', 'Angola',                           '+244',  'Africa',   'AOA', false),
        (NEW.client_id, NEW.id, 'BJ', 'BEN', 'Benin',                            '+229',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'BW', 'BWA', 'Botswana',                         '+267',  'Africa',   'BWP', false),
        (NEW.client_id, NEW.id, 'BF', 'BFA', 'Burkina Faso',                     '+226',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'BI', 'BDI', 'Burundi',                          '+257',  'Africa',   'BIF', false),
        (NEW.client_id, NEW.id, 'CV', 'CPV', 'Cape Verde',                       '+238',  'Africa',   'CVE', false),
        (NEW.client_id, NEW.id, 'CM', 'CMR', 'Cameroon',                         '+237',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'CF', 'CAF', 'Central African Republic',         '+236',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'TD', 'TCD', 'Chad',                             '+235',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'KM', 'COM', 'Comoros',                          '+269',  'Africa',   'KMF', false),
        (NEW.client_id, NEW.id, 'CD', 'COD', 'Democratic Republic of Congo',     '+243',  'Africa',   'CDF', false),
        (NEW.client_id, NEW.id, 'CG', 'COG', 'Republic of Congo',                '+242',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'CI', 'CIV', 'Ivory Coast',                      '+225',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'DJ', 'DJI', 'Djibouti',                         '+253',  'Africa',   'DJF', false),
        (NEW.client_id, NEW.id, 'EG', 'EGY', 'Egypt',                            '+20',   'Africa',   'EGP', false),
        (NEW.client_id, NEW.id, 'GQ', 'GNQ', 'Equatorial Guinea',                '+240',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'ER', 'ERI', 'Eritrea',                          '+291',  'Africa',   'ERN', false),
        (NEW.client_id, NEW.id, 'SZ', 'SWZ', 'Eswatini',                         '+268',  'Africa',   'SZL', false),
        (NEW.client_id, NEW.id, 'ET', 'ETH', 'Ethiopia',                         '+251',  'Africa',   'ETB', false),
        (NEW.client_id, NEW.id, 'GA', 'GAB', 'Gabon',                            '+241',  'Africa',   'XAF', false),
        (NEW.client_id, NEW.id, 'GM', 'GMB', 'Gambia',                           '+220',  'Africa',   'GMD', false),
        (NEW.client_id, NEW.id, 'GH', 'GHA', 'Ghana',                            '+233',  'Africa',   'GHS', false),
        (NEW.client_id, NEW.id, 'GN', 'GIN', 'Guinea',                           '+224',  'Africa',   'GNF', false),
        (NEW.client_id, NEW.id, 'GW', 'GNB', 'Guinea-Bissau',                    '+245',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'KE', 'KEN', 'Kenya',                            '+254',  'Africa',   'KES', false),
        (NEW.client_id, NEW.id, 'LS', 'LSO', 'Lesotho',                          '+266',  'Africa',   'LSL', false),
        (NEW.client_id, NEW.id, 'LR', 'LBR', 'Liberia',                          '+231',  'Africa',   'LRD', false),
        (NEW.client_id, NEW.id, 'LY', 'LBY', 'Libya',                            '+218',  'Africa',   'LYD', false),
        (NEW.client_id, NEW.id, 'MG', 'MDG', 'Madagascar',                       '+261',  'Africa',   'MGA', false),
        (NEW.client_id, NEW.id, 'MW', 'MWI', 'Malawi',                           '+265',  'Africa',   'MWK', false),
        (NEW.client_id, NEW.id, 'ML', 'MLI', 'Mali',                             '+223',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'MR', 'MRT', 'Mauritania',                       '+222',  'Africa',   'MRU', false),
        (NEW.client_id, NEW.id, 'MU', 'MUS', 'Mauritius',                        '+230',  'Africa',   'MUR', false),
        (NEW.client_id, NEW.id, 'MA', 'MAR', 'Morocco',                          '+212',  'Africa',   'MAD', false),
        (NEW.client_id, NEW.id, 'MZ', 'MOZ', 'Mozambique',                       '+258',  'Africa',   'MZN', false),
        (NEW.client_id, NEW.id, 'NA', 'NAM', 'Namibia',                          '+264',  'Africa',   'NAD', false),
        (NEW.client_id, NEW.id, 'NE', 'NER', 'Niger',                            '+227',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'NG', 'NGA', 'Nigeria',                          '+234',  'Africa',   'NGN', false),
        (NEW.client_id, NEW.id, 'RW', 'RWA', 'Rwanda',                           '+250',  'Africa',   'RWF', false),
        (NEW.client_id, NEW.id, 'ST', 'STP', 'Sao Tome and Principe',            '+239',  'Africa',   'STN', false),
        (NEW.client_id, NEW.id, 'SN', 'SEN', 'Senegal',                          '+221',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'SC', 'SYC', 'Seychelles',                       '+248',  'Africa',   'SCR', false),
        (NEW.client_id, NEW.id, 'SL', 'SLE', 'Sierra Leone',                     '+232',  'Africa',   'SLE', false),
        (NEW.client_id, NEW.id, 'SO', 'SOM', 'Somalia',                          '+252',  'Africa',   'SOS', false),
        (NEW.client_id, NEW.id, 'ZA', 'ZAF', 'South Africa',                     '+27',   'Africa',   'ZAR', false),
        (NEW.client_id, NEW.id, 'SS', 'SSD', 'South Sudan',                      '+211',  'Africa',   'SSP', false),
        (NEW.client_id, NEW.id, 'SD', 'SDN', 'Sudan',                            '+249',  'Africa',   'SDG', false),
        (NEW.client_id, NEW.id, 'TZ', 'TZA', 'Tanzania',                         '+255',  'Africa',   'TZS', false),
        (NEW.client_id, NEW.id, 'TG', 'TGO', 'Togo',                             '+228',  'Africa',   'XOF', false),
        (NEW.client_id, NEW.id, 'TN', 'TUN', 'Tunisia',                          '+216',  'Africa',   'TND', false),
        (NEW.client_id, NEW.id, 'UG', 'UGA', 'Uganda',                           '+256',  'Africa',   'UGX', false),
        (NEW.client_id, NEW.id, 'ZM', 'ZMB', 'Zambia',                           '+260',  'Africa',   'ZMW', false),
        (NEW.client_id, NEW.id, 'ZW', 'ZWE', 'Zimbabwe',                         '+263',  'Africa',   'ZWG', false),

        -- ── Americas ──────────────────────────────────────────────────────────
        (NEW.client_id, NEW.id, 'AG', 'ATG', 'Antigua and Barbuda',              '+1268', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'AR', 'ARG', 'Argentina',                        '+54',   'Americas', 'ARS', false),
        (NEW.client_id, NEW.id, 'AW', 'ABW', 'Aruba',                            '+297',  'Americas', 'AWG', false),
        (NEW.client_id, NEW.id, 'BS', 'BHS', 'Bahamas',                          '+1242', 'Americas', 'BSD', false),
        (NEW.client_id, NEW.id, 'BB', 'BRB', 'Barbados',                         '+1246', 'Americas', 'BBD', false),
        (NEW.client_id, NEW.id, 'BZ', 'BLZ', 'Belize',                           '+501',  'Americas', 'BZD', false),
        (NEW.client_id, NEW.id, 'BM', 'BMU', 'Bermuda',                          '+1441', 'Americas', 'BMD', false),
        (NEW.client_id, NEW.id, 'BO', 'BOL', 'Bolivia',                          '+591',  'Americas', 'BOB', false),
        (NEW.client_id, NEW.id, 'BR', 'BRA', 'Brazil',                           '+55',   'Americas', 'BRL', false),
        (NEW.client_id, NEW.id, 'CA', 'CAN', 'Canada',                           '+1',    'Americas', 'CAD', false),
        (NEW.client_id, NEW.id, 'KY', 'CYM', 'Cayman Islands',                   '+1345', 'Americas', 'KYD', false),
        (NEW.client_id, NEW.id, 'CL', 'CHL', 'Chile',                            '+56',   'Americas', 'CLP', false),
        (NEW.client_id, NEW.id, 'CO', 'COL', 'Colombia',                         '+57',   'Americas', 'COP', false),
        (NEW.client_id, NEW.id, 'CR', 'CRI', 'Costa Rica',                       '+506',  'Americas', 'CRC', false),
        (NEW.client_id, NEW.id, 'CU', 'CUB', 'Cuba',                             '+53',   'Americas', 'CUP', false),
        (NEW.client_id, NEW.id, 'CW', 'CUW', 'Curacao',                          '+599',  'Americas', 'ANG', false),
        (NEW.client_id, NEW.id, 'DM', 'DMA', 'Dominica',                         '+1767', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'DO', 'DOM', 'Dominican Republic',               '+1809', 'Americas', 'DOP', false),
        (NEW.client_id, NEW.id, 'EC', 'ECU', 'Ecuador',                          '+593',  'Americas', 'USD', false),
        (NEW.client_id, NEW.id, 'SV', 'SLV', 'El Salvador',                      '+503',  'Americas', 'USD', false),
        (NEW.client_id, NEW.id, 'FK', 'FLK', 'Falkland Islands',                 '+500',  'Americas', 'FKP', false),
        (NEW.client_id, NEW.id, 'GD', 'GRD', 'Grenada',                          '+1473', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'GT', 'GTM', 'Guatemala',                        '+502',  'Americas', 'GTQ', false),
        (NEW.client_id, NEW.id, 'GY', 'GUY', 'Guyana',                           '+592',  'Americas', 'GYD', false),
        (NEW.client_id, NEW.id, 'HT', 'HTI', 'Haiti',                            '+509',  'Americas', 'HTG', false),
        (NEW.client_id, NEW.id, 'HN', 'HND', 'Honduras',                         '+504',  'Americas', 'HNL', false),
        (NEW.client_id, NEW.id, 'JM', 'JAM', 'Jamaica',                          '+1876', 'Americas', 'JMD', false),
        (NEW.client_id, NEW.id, 'MX', 'MEX', 'Mexico',                           '+52',   'Americas', 'MXN', false),
        (NEW.client_id, NEW.id, 'NI', 'NIC', 'Nicaragua',                        '+505',  'Americas', 'NIO', false),
        (NEW.client_id, NEW.id, 'PA', 'PAN', 'Panama',                           '+507',  'Americas', 'PAB', false),
        (NEW.client_id, NEW.id, 'PY', 'PRY', 'Paraguay',                         '+595',  'Americas', 'PYG', false),
        (NEW.client_id, NEW.id, 'PE', 'PER', 'Peru',                             '+51',   'Americas', 'PEN', false),
        (NEW.client_id, NEW.id, 'KN', 'KNA', 'Saint Kitts and Nevis',            '+1869', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'LC', 'LCA', 'Saint Lucia',                      '+1758', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'VC', 'VCT', 'Saint Vincent and the Grenadines', '+1784', 'Americas', 'XCD', false),
        (NEW.client_id, NEW.id, 'SR', 'SUR', 'Suriname',                         '+597',  'Americas', 'SRD', false),
        (NEW.client_id, NEW.id, 'TT', 'TTO', 'Trinidad and Tobago',              '+1868', 'Americas', 'TTD', false),
        (NEW.client_id, NEW.id, 'US', 'USA', 'United States',                    '+1',    'Americas', 'USD', false),
        (NEW.client_id, NEW.id, 'UY', 'URY', 'Uruguay',                          '+598',  'Americas', 'UYU', false),
        (NEW.client_id, NEW.id, 'VE', 'VEN', 'Venezuela',                        '+58',   'Americas', 'VES', false),

        -- ── Asia ──────────────────────────────────────────────────────────────
        (NEW.client_id, NEW.id, 'AF', 'AFG', 'Afghanistan',                      '+93',   'Asia',     'AFN', false),
        (NEW.client_id, NEW.id, 'AM', 'ARM', 'Armenia',                          '+374',  'Asia',     'AMD', false),
        (NEW.client_id, NEW.id, 'AZ', 'AZE', 'Azerbaijan',                       '+994',  'Asia',     'AZN', false),
        (NEW.client_id, NEW.id, 'BH', 'BHR', 'Bahrain',                          '+973',  'Asia',     'BHD', false),
        (NEW.client_id, NEW.id, 'BD', 'BGD', 'Bangladesh',                       '+880',  'Asia',     'BDT', false),
        (NEW.client_id, NEW.id, 'BT', 'BTN', 'Bhutan',                           '+975',  'Asia',     'BTN', false),
        (NEW.client_id, NEW.id, 'BN', 'BRN', 'Brunei',                           '+673',  'Asia',     'BND', false),
        (NEW.client_id, NEW.id, 'KH', 'KHM', 'Cambodia',                         '+855',  'Asia',     'KHR', false),
        (NEW.client_id, NEW.id, 'CN', 'CHN', 'China',                            '+86',   'Asia',     'CNY', false),
        (NEW.client_id, NEW.id, 'GE', 'GEO', 'Georgia',                          '+995',  'Asia',     'GEL', false),
        (NEW.client_id, NEW.id, 'HK', 'HKG', 'Hong Kong',                        '+852',  'Asia',     'HKD', false),
        (NEW.client_id, NEW.id, 'IN', 'IND', 'India',                            '+91',   'Asia',     'INR', false),
        (NEW.client_id, NEW.id, 'ID', 'IDN', 'Indonesia',                        '+62',   'Asia',     'IDR', false),
        (NEW.client_id, NEW.id, 'IR', 'IRN', 'Iran',                             '+98',   'Asia',     'IRR', false),
        (NEW.client_id, NEW.id, 'IQ', 'IRQ', 'Iraq',                             '+964',  'Asia',     'IQD', false),
        (NEW.client_id, NEW.id, 'IL', 'ISR', 'Israel',                           '+972',  'Asia',     'ILS', false),
        (NEW.client_id, NEW.id, 'JP', 'JPN', 'Japan',                            '+81',   'Asia',     'JPY', false),
        (NEW.client_id, NEW.id, 'JO', 'JOR', 'Jordan',                           '+962',  'Asia',     'JOD', false),
        (NEW.client_id, NEW.id, 'KZ', 'KAZ', 'Kazakhstan',                       '+7',    'Asia',     'KZT', false),
        (NEW.client_id, NEW.id, 'KW', 'KWT', 'Kuwait',                           '+965',  'Asia',     'KWD', false),
        (NEW.client_id, NEW.id, 'KG', 'KGZ', 'Kyrgyzstan',                       '+996',  'Asia',     'KGS', false),
        (NEW.client_id, NEW.id, 'LA', 'LAO', 'Laos',                             '+856',  'Asia',     'LAK', false),
        (NEW.client_id, NEW.id, 'LB', 'LBN', 'Lebanon',                          '+961',  'Asia',     'LBP', false),
        (NEW.client_id, NEW.id, 'MO', 'MAC', 'Macau',                            '+853',  'Asia',     'MOP', false),
        (NEW.client_id, NEW.id, 'MY', 'MYS', 'Malaysia',                         '+60',   'Asia',     'MYR', false),
        (NEW.client_id, NEW.id, 'MV', 'MDV', 'Maldives',                         '+960',  'Asia',     'MVR', false),
        (NEW.client_id, NEW.id, 'MN', 'MNG', 'Mongolia',                         '+976',  'Asia',     'MNT', false),
        (NEW.client_id, NEW.id, 'MM', 'MMR', 'Myanmar',                          '+95',   'Asia',     'MMK', false),
        (NEW.client_id, NEW.id, 'NP', 'NPL', 'Nepal',                            '+977',  'Asia',     'NPR', false),
        (NEW.client_id, NEW.id, 'KP', 'PRK', 'North Korea',                      '+850',  'Asia',     'KPW', false),
        (NEW.client_id, NEW.id, 'OM', 'OMN', 'Oman',                             '+968',  'Asia',     'OMR', false),
        (NEW.client_id, NEW.id, 'PK', 'PAK', 'Pakistan',                         '+92',   'Asia',     'PKR', false),
        (NEW.client_id, NEW.id, 'PS', 'PSE', 'Palestine',                        '+970',  'Asia',     'ILS', false),
        (NEW.client_id, NEW.id, 'PH', 'PHL', 'Philippines',                      '+63',   'Asia',     'PHP', false),
        (NEW.client_id, NEW.id, 'QA', 'QAT', 'Qatar',                            '+974',  'Asia',     'QAR', false),
        (NEW.client_id, NEW.id, 'SA', 'SAU', 'Saudi Arabia',                     '+966',  'Asia',     'SAR', false),
        (NEW.client_id, NEW.id, 'SG', 'SGP', 'Singapore',                        '+65',   'Asia',     'SGD', false),
        (NEW.client_id, NEW.id, 'KR', 'KOR', 'South Korea',                      '+82',   'Asia',     'KRW', false),
        (NEW.client_id, NEW.id, 'LK', 'LKA', 'Sri Lanka',                        '+94',   'Asia',     'LKR', false),
        (NEW.client_id, NEW.id, 'SY', 'SYR', 'Syria',                            '+963',  'Asia',     'SYP', false),
        (NEW.client_id, NEW.id, 'TW', 'TWN', 'Taiwan',                           '+886',  'Asia',     'TWD', false),
        (NEW.client_id, NEW.id, 'TJ', 'TJK', 'Tajikistan',                       '+992',  'Asia',     'TJS', false),
        (NEW.client_id, NEW.id, 'TH', 'THA', 'Thailand',                         '+66',   'Asia',     'THB', false),
        (NEW.client_id, NEW.id, 'TL', 'TLS', 'Timor-Leste',                      '+670',  'Asia',     'USD', false),
        (NEW.client_id, NEW.id, 'TM', 'TKM', 'Turkmenistan',                     '+993',  'Asia',     'TMT', false),
        (NEW.client_id, NEW.id, 'TR', 'TUR', 'Turkey',                           '+90',   'Asia',     'TRY', false),
        (NEW.client_id, NEW.id, 'AE', 'ARE', 'United Arab Emirates',             '+971',  'Asia',     'AED', false),
        (NEW.client_id, NEW.id, 'UZ', 'UZB', 'Uzbekistan',                       '+998',  'Asia',     'UZS', false),
        (NEW.client_id, NEW.id, 'VN', 'VNM', 'Vietnam',                          '+84',   'Asia',     'VND', false),
        (NEW.client_id, NEW.id, 'YE', 'YEM', 'Yemen',                            '+967',  'Asia',     'YER', false),

        -- ── Europe ────────────────────────────────────────────────────────────
        (NEW.client_id, NEW.id, 'AL', 'ALB', 'Albania',                          '+355',  'Europe',   'ALL', false),
        (NEW.client_id, NEW.id, 'AD', 'AND', 'Andorra',                          '+376',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'AT', 'AUT', 'Austria',                          '+43',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'BY', 'BLR', 'Belarus',                          '+375',  'Europe',   'BYN', false),
        (NEW.client_id, NEW.id, 'BE', 'BEL', 'Belgium',                          '+32',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'BA', 'BIH', 'Bosnia and Herzegovina',           '+387',  'Europe',   'BAM', false),
        (NEW.client_id, NEW.id, 'BG', 'BGR', 'Bulgaria',                         '+359',  'Europe',   'BGN', false),
        (NEW.client_id, NEW.id, 'HR', 'HRV', 'Croatia',                          '+385',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'CY', 'CYP', 'Cyprus',                           '+357',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'CZ', 'CZE', 'Czech Republic',                   '+420',  'Europe',   'CZK', false),
        (NEW.client_id, NEW.id, 'DK', 'DNK', 'Denmark',                          '+45',   'Europe',   'DKK', false),
        (NEW.client_id, NEW.id, 'EE', 'EST', 'Estonia',                          '+372',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'FI', 'FIN', 'Finland',                          '+358',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'FR', 'FRA', 'France',                           '+33',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'DE', 'DEU', 'Germany',                          '+49',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'GI', 'GIB', 'Gibraltar',                        '+350',  'Europe',   'GIP', false),
        (NEW.client_id, NEW.id, 'GR', 'GRC', 'Greece',                           '+30',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'HU', 'HUN', 'Hungary',                          '+36',   'Europe',   'HUF', false),
        (NEW.client_id, NEW.id, 'IS', 'ISL', 'Iceland',                          '+354',  'Europe',   'ISK', false),
        (NEW.client_id, NEW.id, 'IE', 'IRL', 'Ireland',                          '+353',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'IT', 'ITA', 'Italy',                            '+39',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'XK', 'XKX', 'Kosovo',                           '+383',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'LV', 'LVA', 'Latvia',                           '+371',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'LI', 'LIE', 'Liechtenstein',                    '+423',  'Europe',   'CHF', false),
        (NEW.client_id, NEW.id, 'LT', 'LTU', 'Lithuania',                        '+370',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'LU', 'LUX', 'Luxembourg',                       '+352',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'MT', 'MLT', 'Malta',                            '+356',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'MD', 'MDA', 'Moldova',                          '+373',  'Europe',   'MDL', false),
        (NEW.client_id, NEW.id, 'MC', 'MCO', 'Monaco',                           '+377',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'ME', 'MNE', 'Montenegro',                       '+382',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'NL', 'NLD', 'Netherlands',                      '+31',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'MK', 'MKD', 'North Macedonia',                  '+389',  'Europe',   'MKD', false),
        (NEW.client_id, NEW.id, 'NO', 'NOR', 'Norway',                           '+47',   'Europe',   'NOK', false),
        (NEW.client_id, NEW.id, 'PL', 'POL', 'Poland',                           '+48',   'Europe',   'PLN', false),
        (NEW.client_id, NEW.id, 'PT', 'PRT', 'Portugal',                         '+351',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'RO', 'ROU', 'Romania',                          '+40',   'Europe',   'RON', false),
        (NEW.client_id, NEW.id, 'RU', 'RUS', 'Russia',                           '+7',    'Europe',   'RUB', false),
        (NEW.client_id, NEW.id, 'SM', 'SMR', 'San Marino',                       '+378',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'RS', 'SRB', 'Serbia',                           '+381',  'Europe',   'RSD', false),
        (NEW.client_id, NEW.id, 'SH', 'SHN', 'Saint Helena',                     '+290',  'Europe',   'SHP', false),
        (NEW.client_id, NEW.id, 'SK', 'SVK', 'Slovakia',                         '+421',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'SI', 'SVN', 'Slovenia',                         '+386',  'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'ES', 'ESP', 'Spain',                            '+34',   'Europe',   'EUR', false),
        (NEW.client_id, NEW.id, 'SE', 'SWE', 'Sweden',                           '+46',   'Europe',   'SEK', false),
        (NEW.client_id, NEW.id, 'CH', 'CHE', 'Switzerland',                      '+41',   'Europe',   'CHF', false),
        (NEW.client_id, NEW.id, 'UA', 'UKR', 'Ukraine',                          '+380',  'Europe',   'UAH', false),
        (NEW.client_id, NEW.id, 'GB', 'GBR', 'United Kingdom',                   '+44',   'Europe',   'GBP', false),
        (NEW.client_id, NEW.id, 'VA', 'VAT', 'Vatican City',                     '+39',   'Europe',   'EUR', false),

        -- ── Oceania ───────────────────────────────────────────────────────────
        (NEW.client_id, NEW.id, 'AU', 'AUS', 'Australia',                        '+61',   'Oceania',  'AUD', false),
        (NEW.client_id, NEW.id, 'FJ', 'FJI', 'Fiji',                             '+679',  'Oceania',  'FJD', false),
        (NEW.client_id, NEW.id, 'KI', 'KIR', 'Kiribati',                         '+686',  'Oceania',  'AUD', false),
        (NEW.client_id, NEW.id, 'MH', 'MHL', 'Marshall Islands',                 '+692',  'Oceania',  'USD', false),
        (NEW.client_id, NEW.id, 'FM', 'FSM', 'Micronesia',                       '+691',  'Oceania',  'USD', false),
        (NEW.client_id, NEW.id, 'NR', 'NRU', 'Nauru',                            '+674',  'Oceania',  'AUD', false),
        (NEW.client_id, NEW.id, 'NZ', 'NZL', 'New Zealand',                      '+64',   'Oceania',  'NZD', false),
        (NEW.client_id, NEW.id, 'PW', 'PLW', 'Palau',                            '+680',  'Oceania',  'USD', false),
        (NEW.client_id, NEW.id, 'PG', 'PNG', 'Papua New Guinea',                 '+675',  'Oceania',  'PGK', false),
        (NEW.client_id, NEW.id, 'WS', 'WSM', 'Samoa',                            '+685',  'Oceania',  'WST', false),
        (NEW.client_id, NEW.id, 'SB', 'SLB', 'Solomon Islands',                  '+677',  'Oceania',  'SBD', false),
        (NEW.client_id, NEW.id, 'TO', 'TON', 'Tonga',                            '+676',  'Oceania',  'TOP', false),
        (NEW.client_id, NEW.id, 'TV', 'TUV', 'Tuvalu',                           '+688',  'Oceania',  'AUD', false),
        (NEW.client_id, NEW.id, 'VU', 'VUT', 'Vanuatu',                          '+678',  'Oceania',  'VUV', false)

    ON CONFLICT (client_id, company_id, country_code) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_seed_company_countries
    AFTER INSERT ON ric_companies
    FOR EACH ROW
    EXECUTE FUNCTION fn_seed_company_countries();
