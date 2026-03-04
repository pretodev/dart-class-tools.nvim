# dart-class-tools.nvim

Neovim plugin that generates Dart data class boilerplate code — constructor, `copyWith`, `toMap`/`fromMap`, `toJson`/`fromJson`, `toString`, equality (`==` and `hashCode`), and full data class generation.

Inspired by [Dart Data Class Tools Plus](https://github.com/RekanDev/dart-data-class-tools-plus) for VS Code.

## Features

- **Constructor** — auto-detects `const` eligibility, named parameters with `required`, nullable defaults
- **copyWith** — nullable parameter overrides with correct type handling
- **toMap / fromMap** — serialization with `as` casting, enum `.name` serialization, DateTime ISO 8601, nested custom types
- **toJson / fromJson** — via `dart:convert` (delegates to toMap/fromMap)
- **toString** — short (arrow) form for <= 4 properties, block form for larger classes
- **Equality** — `operator ==` with `identical` check, collection equality via `ListEquality`/`MapEquality`/`SetEquality`
- **hashCode** — XOR-based, short/long form matching toString
- **Full data class** — generates all of the above in one action

### Dart-aware behavior

- Detects enum types in the file and generates enum-specific serialization (`.name`, `firstWhere`/`firstWhereOrNull`)
- Handles nullable fields, collections (`List`, `Map`, `Set`), `DateTime`, nested custom types
- Skips `late` fields from code generation while preserving them in the class body
- Respects abstract/sealed classes (skips copyWith and serialization)
- Supports Flutter widgets (adds `Key? key` parameter, `super(key: key)`)
- Skips `State<T>` classes entirely
- Auto-inserts required imports (`dart:convert`, `package:collection/collection.dart`)
- Uses `const` constructor when all gen-eligible properties are `final` and no `late` fields exist
- Generated code passes `dart analyze` and `dart format` with zero issues

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "pretodev/dart-class-tools.nvim",
  ft = "dart",
  opts = {},
}
```

## Configuration

All options with their defaults:

```lua
require("dart-class-tools").setup({
  -- Use `as Type` casting in fromMap (default: true)
  use_as_cast = true,

  -- Generate default values for non-nullable fields in fromMap (default: false)
  use_default_values = false,

  -- Generate default values for constructor parameters (default: false)
  constructor_default_values = false,

  -- Use Jenkins hash (hashList) instead of XOR (default: false)
  use_jenkins_hash = false,

  -- Use ValueGetter<T?> for nullable params in copyWith (default: false)
  use_value_getter = false,

  -- JSON key format: "variable" (as-is), "snake_case", or "camelCase"
  json_key_format = "variable",

  -- Keymaps (set to false to disable)
  keymaps = {
    code_action = "<leader>dc",
  },
})
```

## Usage

### Via code actions (recommended)

Place your cursor on a class declaration, property, or constructor line and trigger code actions:

- **`<leader>dc`** — opens the dart-class-tools action picker
- **`:DartClassGenerate`** — same as above, via command
- **`vim.lsp.buf.code_action()`** — actions appear alongside LSP code actions

### Available actions

| Action | Description |
|---|---|
| Generate data class | All methods at once |
| Generate constructor | Named constructor with required params |
| Generate copyWith | Immutable copy with overrides |
| Generate toMap | Serialize to `Map<String, dynamic>` |
| Generate fromMap | Deserialize from map (factory) |
| Generate toJson | Encode to JSON string |
| Generate fromJson | Decode from JSON string (factory) |
| Generate toString | Debug-friendly string representation |
| Generate equality | `operator ==` and `hashCode` |

Actions only appear when:
- The cursor is on a valid Dart class (not an enum declaration)
- The cursor is on the class declaration line, a property line, or inside the constructor
- The method doesn't already exist in the class

### Example

Given this input:

```dart
class User {
  final String name;
  final int age;
  final String? email;
  final bool isActive;
}
```

Running "Generate data class" produces:

```dart
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

  User copyWith({
    String? name,
    int? age,
    String? email,
    bool? isActive,
  }) {
    return User(
      name: name ?? this.name,
      age: age ?? this.age,
      email: email ?? this.email,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'age': age,
      'email': email,
      'isActive': isActive,
    };
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
```

## Known limitations

- **Generic type parameters** (`Pair<A, B>`) — treated as custom types, so `toMap`/`fromMap` generate `.toMap()`/`.fromMap()` calls on the type parameters which won't compile. This matches the reference extension's behavior.
- **Subclass constructors** — generated constructors for subclasses don't automatically include `super()` calls with parent parameters. Users need to manually adjust the super initializer.
- **Cross-file type resolution** — the parser only analyzes the current file. Types defined in other files are treated as custom (non-primitive) types.

## License

MIT
