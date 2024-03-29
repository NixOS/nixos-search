use std::fmt::Display;

use serde_json::Value;

struct Indent(usize);
impl Indent {
    fn next(&self) -> Indent {
        Indent(self.0 + 1)
    }
}

impl Display for Indent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:width$}", "", width = self.0 * 2)
    }
}

pub fn print_value(value: &Value) -> String {
    print_value_indent(value, Indent(0))
}

/// Formats an attrset key by adding quotes when necessary
fn format_attrset_key(key: &str) -> String {
    if key.contains("/")
        || key.contains(" ")
        || key.is_empty()
        || (b'0'..=b'9').contains(&key.as_bytes()[0])
    {
        format!("{:?}", key)
    } else {
        key.to_string()
    }
}

fn print_value_indent(value: &Value, indent: Indent) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(b) => format!("{}", b),
        Value::Number(n) => format!("{}", n),
        Value::String(s) => {
            let lines: Vec<&str> = s.lines().collect();
            if lines.len() > 1 {
                let lines = lines.join(&format!("\n{}", indent.next()));
                return format!(
                    r#"''
{next_indent}{lines}
{indent}''"#,
                    indent = indent,
                    next_indent = indent.next(),
                    lines = lines
                );
            }

            format!("{:?}", s)
        }
        Value::Array(a) => {
            if a.is_empty() {
                return "[ ]".to_owned();
            }
            if a.len() == 1 {
                // Return early if the wrapped value fits on one line
                let val = print_value(a.first().unwrap());
                if !val.contains("\n") {
                    return format!("[ {} ]", val);
                }
            }

            let items = a
                .into_iter()
                .map(|v| print_value_indent(v, indent.next()))
                .collect::<Vec<_>>()
                .join(&format!("\n{}", indent.next()));

            return format!(
                "[
{next_indent}{items}
{indent}]",
                indent = indent,
                next_indent = indent.next(),
                items = items
            );
        }
        Value::Object(o) => {
            if o.is_empty() {
                return "{ }".to_owned();
            }
            if o.len() == 1 {
                // Return early if the wrapped value fits on one line
                let val = print_value(o.values().next().unwrap());
                if !val.contains("\n") {
                    return format!(
                        "{{ {} = {}; }}",
                        format_attrset_key(o.keys().next().unwrap()),
                        val
                    );
                }
            }
            let items = o
                .into_iter()
                .map(|(k, v)| {
                    format!(
                        "{} = {}",
                        format_attrset_key(&k),
                        print_value_indent(v, indent.next())
                    )
                })
                .collect::<Vec<_>>()
                .join(&format!(";\n{}", indent.next()));

            return format!(
                "{{
{next_indent}{items};
{indent}}}",
                indent = indent,
                next_indent = indent.next(),
                items = items
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn test_string() {
        let json = json!("Hello World");
        assert_eq!(print_value(&json), "\"Hello World\"");
    }

    #[test]
    fn test_multi_line_string() {
        let json = json!(
            r#"   Hello
World
!!!"#
        );
        assert_eq!(
            print_value(&json),
            r#"''
     Hello
  World
  !!!
''"#
        );
    }

    #[test]
    fn test_num() {
        let json = json!(1);
        assert_eq!(print_value(&json), "1");
    }

    #[test]
    fn test_bool() {
        let json = json!(true);
        assert_eq!(print_value(&json), "true");
    }

    #[test]
    fn test_empty_list() {
        let json = json!([]);
        assert_eq!(print_value(&json), "[ ]");
    }

    #[test]
    fn test_list_one_item() {
        let json = json!([1]);
        assert_eq!(print_value(&json), "[ 1 ]");
    }

    #[test]
    fn test_list_one_multiline_item() {
        let json = json!(["first line\nsecond line"]);
        assert_eq!(
            print_value(&json),
            r#"[
  ''
    first line
    second line
  ''
]"#
        );
    }

    #[test]
    fn test_filled_list() {
        let json = json!([1, "hello", true, null]);
        assert_eq!(
            print_value(&json),
            r#"[
  1
  "hello"
  true
  null
]"#
        );
    }

    #[test]
    fn test_empty_set() {
        let json = json!({});
        assert_eq!(print_value(&json), "{ }");
    }

    #[test]
    fn test_set_one_item() {
        let json = json!({ "hello": "world" });
        assert_eq!(print_value(&json), "{ hello = \"world\"; }");
    }

    #[test]
    fn test_set_number_key() {
        let json = json!({ "1hello": "world" });
        assert_eq!(print_value(&json), "{ \"1hello\" = \"world\"; }");
    }

    #[test]
    fn test_set_one_multiline_item() {
        let json = json!({ "hello": "pretty\nworld" });
        assert_eq!(
            print_value(&json),
            "{
  hello = ''
    pretty
    world
  '';
}"
        );
    }

    #[test]
    fn test_filled_set() {
        let json = json!({"hello": "world", "another": "test"});
        assert_eq!(
            print_value(&json),
            "{
  another = \"test\";
  hello = \"world\";
}"
        );
    }

    #[test]
    fn test_nested() {
        let json = json!(
        [
          "HDMI-0",
          {
            "output": "DVI-0",
            "primary": true
          },
          {
            "monitorConfig": "Option \"Rotate\" \"left\"",
            "output": "DVI-1"
          },
          [ "hello", "word" ]
        ]);

        assert_eq!(
            print_value(&json),
            r#"[
  "HDMI-0"
  {
    output = "DVI-0";
    primary = true;
  }
  {
    monitorConfig = "Option \"Rotate\" \"left\"";
    output = "DVI-1";
  }
  [
    "hello"
    "word"
  ]
]"#
        );
    }
}
