# Code fence highlighting languages

Every fence below should highlight language tokens. Comments, strings and keywords should have distinct colors where the grammar and theme distinguish them. Switch system appearance to check light and dark palettes.

## rust

```rust
// Rust comment
fn main() {
    let message = "Hello 😀";
    println!("{}", message);
}
```

## python

```python
# Python comment
def greet(name: str):
    message = f"Hello {name}"
    return message

```

## javascript

```javascript
// JavaScript comment
function greet(name) {
  const message = `Hello ${name}`;
  return message;
}
```

## json

```json
{ "message": "Hello", "count": 42, "ready": true, "missing": null }
```

## html

```html
<!-- HTML comment -->
<div class="greeting">Hello &amp; goodbye</div>
```

## css

```css
/* CSS comment */
.greeting { color: #663399; margin: 12px; }
```

## sql

```sql
-- SQL comment
SELECT name, COUNT(*) FROM documents WHERE ready = TRUE GROUP BY name;
```

## bash

```bash
#!/bin/bash
# Shell comment
name="World"
printf "%s\n" "$name"
```

## yaml

```yaml
# YAML comment
renderer:
  enabled: true
  version: 5.3
  names: [rust, python]
```

## cpp

```cpp
// C++ comment
#include <string>
int main() { std::string value = "Hello"; return 0; }
```

## go

```go
// Go comment
package main
import "fmt"
func main() { fmt.Println("Hello") }
```

## xml

```xml
<!-- XML comment -->
<document enabled="true"><title>Hello</title></document>
```
