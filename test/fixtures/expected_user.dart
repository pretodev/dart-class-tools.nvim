import 'dart:convert';

class User {
  final String name;
  final int age;
  final String? email;
  final bool isActive;

  const User({
    required this.name,
    required this.age,
    this.email,
    required this.isActive,
  });

  User copyWith({String? name, int? age, String? email, bool? isActive}) {
    return User(
      name: name ?? this.name,
      age: age ?? this.age,
      email: email ?? this.email,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toMap() {
    return {'name': name, 'age': age, 'email': email, 'isActive': isActive};
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      name: map['name'] as String,
      age: map['age'] as int,
      email: map['email'] as String?,
      isActive: map['isActive'] as bool,
    );
  }

  String toJson() => json.encode(toMap());

  factory User.fromJson(String source) =>
      User.fromMap(Map<String, dynamic>.from(json.decode(source)));

  @override
  String toString() =>
      'User(name: $name, age: $age, email: $email, isActive: $isActive)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is User &&
        other.name == name &&
        other.age == age &&
        other.email == email &&
        other.isActive == isActive;
  }

  @override
  int get hashCode =>
      name.hashCode ^ age.hashCode ^ email.hashCode ^ isActive.hashCode;
}
