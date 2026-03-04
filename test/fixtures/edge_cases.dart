// Edge case test: class with generics
class Pair<A, B> {
  final A first;
  final B second;
}

// Edge case test: abstract class
abstract class Animal {
  final String name;
  final int age;
}

// Edge case test: sealed class
sealed class Shape {
  final String color;
}

// Edge case test: class with non-final fields
class MutableConfig {
  String host;
  int port;
}

// Edge case test: class with mixed final/non-final
class MixedFields {
  final String id;
  String name;
  final int count;
}

// Edge case test: class with existing constructor
class WithConstructor {
  final String name;
  final int age;

  const WithConstructor({required this.name, required this.age});
}

// Edge case test: class extending another
class Dog extends Animal {
  final String breed;
}

// Edge case test: class with late field (should be skipped)
class WithLate {
  final String name;
  late final String computed;
}

// Edge case test: class with single property
class Wrapper {
  final String value;
}

// Edge case test: class with many properties (> 4)
class LargeClass {
  final String a;
  final String b;
  final String c;
  final String d;
  final String e;
}

// Edge case test: class with nullable collections
class NullableCollections {
  final List<String>? tags;
  final Map<String, dynamic>? metadata;
  final Set<int>? ids;
}

// Edge case test: class with DateTime fields
class Event {
  final String title;
  final DateTime startTime;
  final DateTime? endTime;
}

// Edge case test: class with nested custom types
class Comment {
  final String text;
  final User author;
  final User? replyTo;
}
