import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/utils/dimension_ranking.dart';

/// 2026-09-03 (Wyzesales_Rebuild_Decisions.md — Dashboard's dimension
/// breakdown pies): pure logic only, no Supabase/Riverpod dependency, same
/// reasoning as target_overlay_test.dart's own top-of-file note.
void main() {
  group('rankEntityCodes', () {
    test('empty when current has no entities at all — nothing to rank', () {
      expect(rankEntityCodes(current: const {}, previous: const {'C1': 500}, mode: DimensionRankMode.top5), isEmpty);
    });

    test('Craig\'s own report (2026-09-03): top5 with only 2 real current-period entities '
        'returns exactly those 2, never padded up to 5 with zero-value previous-period ones', () {
      final result = rankEntityCodes(
        current: const {'C1': 6000, 'C2': 2780},
        // 5 more entities were active last period but have zero activity this period —
        // before this fix these used to pad the remaining 3 "Top 5" slots at R0.
        previous: const {'C1': 5000, 'C2': 2000, 'C3': 900, 'C4': 700, 'C5': 400, 'C6': 300, 'C7': 100},
        mode: DimensionRankMode.top5,
      );
      expect(result, ['C1', 'C2']);
    });

    test('top5 ranks by current value descending and caps at 5 when more than 5 are active', () {
      final result = rankEntityCodes(
        current: const {'A': 10, 'B': 50, 'C': 30, 'D': 20, 'E': 40, 'F': 5},
        previous: const {},
        mode: DimensionRankMode.top5,
      );
      expect(result, ['B', 'E', 'C', 'D', 'A']);
    });

    test('bottom5 also only draws from current-period entities, ascending order', () {
      final result = rankEntityCodes(
        current: const {'A': 10, 'B': 50},
        previous: const {'A': 10, 'B': 50, 'Z': 999}, // Z had huge PREVIOUS activity, zero now
        mode: DimensionRankMode.bottom5,
      );
      expect(result, ['A', 'B']); // never Z — it has no current-period activity to be "bottom" at
    });

    test('diminishing5 deliberately includes an entity that dropped to zero this period — '
        'the one case the current-period-only restriction must NOT apply to', () {
      final result = rankEntityCodes(
        current: const {'A': 100},
        previous: const {'A': 100, 'Z': 900}, // Z: 900 -> 0, the biggest decline
        mode: DimensionRankMode.diminishing5,
      );
      expect(result.first, 'Z');
    });

    test('growth5 deliberately includes a brand-new entity with no previous-period activity', () {
      final result = rankEntityCodes(
        current: const {'A': 100, 'NEW': 500},
        previous: const {'A': 100},
        mode: DimensionRankMode.growth5,
      );
      expect(result.first, 'NEW');
    });

    test('limit is respected when more entities are eligible than requested', () {
      final result = rankEntityCodes(
        current: const {'A': 1, 'B': 2, 'C': 3, 'D': 4},
        previous: const {},
        mode: DimensionRankMode.top5,
        limit: 2,
      );
      expect(result, ['D', 'C']);
    });
  });
}
