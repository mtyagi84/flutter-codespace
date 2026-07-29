// These row types are defined locally inside their own screen files (no
// repository/model layer exists for any of these 5 screens — see CLAUDE.md's
// Map<String,dynamic> elimination rollout notes) rather than under
// data/models/, so the test imports each screen file directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/setup/presentation/screens/cities_screen.dart';
import 'package:sakal/features/setup/presentation/screens/divisions_screen.dart';
import 'package:sakal/features/setup/presentation/screens/currencies_screen.dart';
import 'package:sakal/features/setup/presentation/screens/locations_screen.dart';
import 'package:sakal/features/setup/presentation/screens/users_screen.dart';

void main() {
  group('City', () {
    test('fromJson — missing fields default to safe values, division_id stays nullable', () {
      final c = City.fromJson(const {});
      expect(c.id, '');
      expect(c.cityName, '');
      expect(c.divisionId, isNull);
      expect(c.countryCode, '');
      expect(c.isActive, true);
    });

    test('fromJson — all fields present', () {
      final c = City.fromJson(const {
        'id': 'city-001',
        'city_name': 'Kinshasa',
        'division_id': 'div-001',
        'country_code': 'CD',
        'is_active': false,
      });
      expect(c.cityName, 'Kinshasa');
      expect(c.divisionId, 'div-001');
      expect(c.isActive, false);
    });

    test('copyWith — toggles isActive, leaves every other field untouched', () {
      final c = City.fromJson(const {
        'id': 'city-001', 'city_name': 'Kinshasa', 'division_id': 'div-001',
        'country_code': 'CD', 'is_active': true,
      });
      final toggled = c.copyWith(isActive: false);
      expect(toggled.isActive, false);
      expect(toggled.id, c.id);
      expect(toggled.cityName, c.cityName);
      expect(toggled.divisionId, c.divisionId);
      expect(toggled.countryCode, c.countryCode);
    });

    test('copyWith — omitting isActive keeps the current value (optimistic-update revert pattern)', () {
      final c = City.fromJson(const {'is_active': true});
      final same = c.copyWith();
      expect(same.isActive, true);
    });
  });

  group('Division', () {
    test('fromJson — missing fields default to safe values', () {
      final d = Division.fromJson(const {});
      expect(d.id, '');
      expect(d.countryCode, '');
      expect(d.divisionCode, '');
      expect(d.divisionName, '');
      expect(d.divisionType, 'Province');
      expect(d.isSystem, true);
    });

    test('fromJson — all fields present, custom (non-system) division', () {
      final d = Division.fromJson(const {
        'id': 'div-001',
        'country_code': 'CD',
        'division_code': 'CD-LN',
        'division_name': 'Lualaba Nord',
        'division_type': 'Province',
        'is_system': false,
      });
      expect(d.divisionCode, 'CD-LN');
      expect(d.divisionName, 'Lualaba Nord');
      expect(d.isSystem, false);
    });
  });

  group('Currency', () {
    test('fromJson — missing fields default to safe values (is_active defaults FALSE, unlike City)', () {
      final c = Currency.fromJson(const {});
      expect(c.id, '');
      expect(c.currencyId, '');
      expect(c.currencyName, '');
      expect(c.currencyNotation, '');
      expect(c.currencyCoin, isNull);
      expect(c.countryCode, isNull);
      expect(c.isActive, false);
    });

    test('fromJson — all fields present', () {
      final c = Currency.fromJson(const {
        'id': 'cur-001',
        'currency_id': 'USD',
        'currency_name': 'US Dollar',
        'currency_notation': '\$',
        'currency_coin': 'Cent',
        'country_code': 'US',
        'is_active': true,
      });
      expect(c.currencyId, 'USD');
      expect(c.currencyCoin, 'Cent');
      expect(c.isActive, true);
    });

    test('copyWith — toggles isActive, leaves every other field untouched', () {
      final c = Currency.fromJson(const {
        'id': 'cur-001', 'currency_id': 'USD', 'currency_name': 'US Dollar',
        'currency_notation': '\$', 'is_active': false,
      });
      final toggled = c.copyWith(isActive: true);
      expect(toggled.isActive, true);
      expect(toggled.currencyId, c.currencyId);
      expect(toggled.currencyName, c.currencyName);
    });
  });

  group('Location', () {
    test('fromJson — missing fields default to safe values', () {
      final l = Location.fromJson(const {});
      expect(l.id, '');
      expect(l.locationName, '');
      expect(l.locationShort, isNull);
      expect(l.groupName, isNull);
      expect(l.cityName, isNull);
      expect(l.isNegativeStockAllowed, false);
      expect(l.isIssueAllowed, true);
      expect(l.isActive, true);
    });

    test('fromJson — group and city embeds resolve independently', () {
      final l = Location.fromJson(const {
        'id': 'loc-001',
        'location_name': 'Main Store',
        'location_short': 'MAIN',
        'group_id': 'grp-001',
        'group': {'group_name': 'Kinshasa Group'},
        'city_id': 'city-001',
        'city': {'city_name': 'Kinshasa'},
        'is_negative_stock_allowed': true,
        'is_issue_allowed': false,
        'is_active': true,
      });
      expect(l.groupName, 'Kinshasa Group');
      expect(l.cityName, 'Kinshasa');
      expect(l.isNegativeStockAllowed, true);
      expect(l.isIssueAllowed, false);
    });

    test('fromJson — null group/city embeds do not crash', () {
      final l = Location.fromJson(const {'group': null, 'city': null});
      expect(l.groupName, isNull);
      expect(l.cityName, isNull);
    });
  });

  group('UserRow', () {
    test('fromJson — missing fields default to safe values', () {
      final u = UserRow.fromJson(const {});
      expect(u.id, '');
      expect(u.salutation, isNull);
      expect(u.fullName, '');
      expect(u.username, '');
      expect(u.languageCode, 'en');
      expect(u.theme, 'light');
      expect(u.isActive, true);
      expect(u.defaultLocationId, isNull);
    });

    test('fromJson — all fields present', () {
      final u = UserRow.fromJson(const {
        'id': 'user-001',
        'salutation': 'Mr',
        'full_name': 'John Doe',
        'username': 'jdoe',
        'email': 'jdoe@example.com',
        'phone': '+243900000000',
        'language_code': 'fr',
        'theme': 'dark',
        'photo': 'base64data',
        'is_active': false,
        'default_location_id': 'loc-001',
      });
      expect(u.salutation, 'Mr');
      expect(u.languageCode, 'fr');
      expect(u.theme, 'dark');
      expect(u.isActive, false);
      expect(u.defaultLocationId, 'loc-001');
    });
  });
}
