class User {
  final String name;
  final int age;
  final String? email;
  final bool isActive;
}

class Product {
  final String title;
  final double price;
  final List<String> tags;
  final Map<String, dynamic> metadata;
}

enum Status { active, inactive, pending }

class Order {
  final String id;
  final Status status;
  final Status? previousStatus;
  final DateTime createdAt;
  final List<Product> items;
}

enum Priority {
  low,
  medium,
  high;

  final String label;

  const Priority(this.label);
}

class Task {
  final String title;
  final Priority priority;
}
