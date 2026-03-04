import 'dart:convert';
import 'package:collection/collection.dart';

class Order {
  final String id;
  final Status status;
  final Status? previousStatus;
  final DateTime createdAt;
  final List<Product> items;

  const Order({
    required this.id,
    required this.status,
    this.previousStatus,
    required this.createdAt,
    required this.items,
  });

  Order copyWith({
    String? id,
    Status? status,
    Status? previousStatus,
    DateTime? createdAt,
    List<Product>? items,
  }) {
    return Order(
      id: id ?? this.id,
      status: status ?? this.status,
      previousStatus: previousStatus ?? this.previousStatus,
      createdAt: createdAt ?? this.createdAt,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'status': status.name,
      'previousStatus': previousStatus?.name,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'items': items.map((x) => x.toMap()).toList(),
    };
  }

  factory Order.fromMap(Map<String, dynamic> map) {
    return Order(
      id: map['id'] as String,
      status: Status.values.firstWhere(
        (element) =>
            element.name.toLowerCase() ==
            (map['status'] as String).toLowerCase(),
      ),
      previousStatus: Status.values.firstWhereOrNull(
        (element) =>
            element.name.toLowerCase() ==
            (map['previousStatus'] as String?)?.toLowerCase(),
      ),
      createdAt: DateTime.parse(map['createdAt']).toLocal(),
      items: List<Product>.from(
        (map['items'] as List<dynamic>).map(
          (x) => Product.fromMap(
            Map<String, dynamic>.from(x as Map<String, dynamic>),
          ),
        ),
      ),
    );
  }

  String toJson() => json.encode(toMap());

  factory Order.fromJson(String source) =>
      Order.fromMap(Map<String, dynamic>.from(json.decode(source)));

  @override
  String toString() {
    return 'Order(id: $id, status: $status, previousStatus: $previousStatus, createdAt: $createdAt, items: $items)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const ListEquality().equals;

    return other is Order &&
        other.id == id &&
        other.status == status &&
        other.previousStatus == previousStatus &&
        other.createdAt == createdAt &&
        listEquals(other.items, items);
  }

  @override
  int get hashCode {
    return id.hashCode ^
        status.hashCode ^
        previousStatus.hashCode ^
        createdAt.hashCode ^
        items.hashCode;
  }
}
