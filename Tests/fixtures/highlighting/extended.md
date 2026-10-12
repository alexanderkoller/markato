# Additional grammars from two-face

Each fence should display colored tokens and preserve its literal source. Typst here is highlighted source code.

## Swift

```swift
// Swift comment
struct Greeting {
    let message: String = "Grüße 😀 & < >"
    func render() -> String { return message }
}
```

## TypeScript

```typescript
// TypeScript comment
type Greeting = { message: string; ready: boolean };
const value: Greeting = { message: "Hello", ready: true };
```

## TSX

```tsx
// TSX comment
type Props = { name: string };
const Greeting = ({ name }: Props) => <div className="greeting">Hello {name}</div>;
```

## Kotlin

```kotlin
// Kotlin comment
data class Greeting(val message: String)
fun main() { println(Greeting("Hello 😀")) }
```

## Dart

```dart
// Dart comment
class Greeting {
  final String message;
  Greeting(this.message);
}
void main() { print(Greeting('Hello').message); }
```

## TOML

```toml
# TOML comment
[renderer]
name = "Markato"
enabled = true
languages = ["swift", "typst"]
```

## Dockerfile

```dockerfile
# Dockerfile comment
FROM rust:1.96 AS builder
WORKDIR /app
COPY . .
RUN cargo build --release
ENV MESSAGE="Hello"
```

## Typst

```typst
// Typst comment
#set text(size: 12pt)
#let greet(name) = [Hello, #name!]
= A heading
#greet("Grüße 😀 & < >")
$ x^2 + y^2 = z^2 $
*Bold text* and a #link("https://example.invalid")[link].
```
