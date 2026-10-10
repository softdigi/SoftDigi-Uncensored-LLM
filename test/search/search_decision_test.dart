import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/search/search_decision.dart';

void main() {
  group('SearchDecision.needsWebSearch', () {
    test('a timeless factual question does not need the web', () {
      expect(SearchDecision.needsWebSearch('What is gravity?'), isFalse);
      expect(
        SearchDecision.needsWebSearch('Explain how photosynthesis works.'),
        isFalse,
      );
      expect(SearchDecision.needsWebSearch('Write a haiku about rain.'), isFalse);
    });

    test('a current-information question needs the web', () {
      expect(
        SearchDecision.needsWebSearch("What is today's gold price?"),
        isTrue,
      );
      expect(SearchDecision.needsWebSearch('What is the latest news?'), isTrue);
      expect(
        SearchDecision.needsWebSearch("What's the weather right now?"),
        isTrue,
      );
      expect(SearchDecision.needsWebSearch('Who won the election?'), isTrue);
    });

    test('matching is case-insensitive', () {
      expect(SearchDecision.needsWebSearch('TODAY is a good day'), isTrue);
    });

    test('matches whole words only, not substrings of other words', () {
      // "current" should not fire on "concurrent", "currently" is its own
      // explicit trigger but "occurrence" must not match "current".
      expect(SearchDecision.needsWebSearch('a concurrent process'), isFalse);
      expect(SearchDecision.needsWebSearch('an occurrence of bugs'), isFalse);
    });
  });
}
