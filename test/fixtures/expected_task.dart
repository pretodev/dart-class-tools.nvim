import 'dart:convert';

class Task {
  final String title;
  final Priority priority;

  const Task({required this.title, required this.priority});

  Task copyWith({String? title, Priority? priority}) {
    return Task(
      title: title ?? this.title,
      priority: priority ?? this.priority,
    );
  }

  Map<String, dynamic> toMap() {
    return {'title': title, 'priority': priority.name};
  }

  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      title: map['title'] as String,
      priority: Priority.values.firstWhere(
        (element) =>
            element.name.toLowerCase() ==
            (map['priority'] as String).toLowerCase(),
      ),
    );
  }

  String toJson() => json.encode(toMap());

  factory Task.fromJson(String source) =>
      Task.fromMap(Map<String, dynamic>.from(json.decode(source)));

  @override
  String toString() => 'Task(title: $title, priority: $priority)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Task && other.title == title && other.priority == priority;
  }

  @override
  int get hashCode => title.hashCode ^ priority.hashCode;
}
