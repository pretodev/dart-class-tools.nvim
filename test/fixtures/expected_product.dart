import 'dart:convert';
import 'package:collection/collection.dart';

class Product {
  final String title;
  final double price;
  final List<String> tags;
  final Map<String, dynamic> metadata;

  const Product({
    required this.title,
    required this.price,
    required this.tags,
    required this.metadata,
  });

  Product copyWith({
    String? title,
    double? price,
    List<String>? tags,
    Map<String, dynamic>? metadata,
  }) {
    return Product(
      title: title ?? this.title,
      price: price ?? this.price,
      tags: tags ?? this.tags,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toMap() {
    return {'title': title, 'price': price, 'tags': tags, 'metadata': metadata};
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      title: map['title'] as String,
      price: map['price'] as double,
      tags: List<String>.from(map['tags'] as List<dynamic>),
      metadata: Map<String, dynamic>.from(
        map['metadata'] as Map<String, dynamic>,
      ),
    );
  }

  String toJson() => json.encode(toMap());

  factory Product.fromJson(String source) =>
      Product.fromMap(Map<String, dynamic>.from(json.decode(source)));

  @override
  String toString() =>
      'Product(title: $title, price: $price, tags: $tags, metadata: $metadata)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const ListEquality().equals;
    final mapEquals = const MapEquality().equals;

    return other is Product &&
        other.title == title &&
        other.price == price &&
        listEquals(other.tags, tags) &&
        mapEquals(other.metadata, metadata);
  }

  @override
  int get hashCode =>
      title.hashCode ^ price.hashCode ^ tags.hashCode ^ metadata.hashCode;
}
