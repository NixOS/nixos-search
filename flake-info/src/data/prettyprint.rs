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

pub fn print_value(value: Value) -> String {
    print_value_indent(value, Indent(0))
}

fn print_value_indent(value: Value, indent: Indent) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(b) => format!("{}", b),
        Value::Number(n) => format!("{}", n),
        Value::String(s) => {
            let lines: Vec<&str> = s.lines().collect();
            if lines.len() > 1 {
                let lines = lines.join(&format!("\n{}", indent.next()));
                return format!(
r#"{indent}''
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
            let items = a
                .into_iter()
                .map(|v| print_value_indent(v, indent.next()))
                .collect::<Vec<_>>()
                .join(&format!("\n{}", indent.next()));

            return format!(
"{indent}[
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
            let items = o
                .into_iter()
                .map(|(k, v)| format!("{} = {}", k, print_value_indent(v, indent.next())))
                .collect::<Vec<_>>()
                .join(&format!(";\n{}", indent.next()));

            return format!(
"{indent}{{
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
        assert_eq!(print_value(json), "\"Hello World\"");
    }

    #[test]
    fn test_multi_line_string() {
        let json = json!(
r#"   Hello
World
!!!"#
        );
        assert_eq!(
            print_value(json),
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
        assert_eq!(print_value(json), "1");
    }

    #[test]
    fn test_bool() {
        let json = json!(true);
        assert_eq!(print_value(json), "true");
    }

    #[test]
    fn test_empty_list() {
        let json = json!([]);
        assert_eq!(print_value(json), "[ ]");
    }

    #[test]
    fn test_filled_list() {
        let json = json!([1, "hello", true, null]);
        assert_eq!(
            print_value(json),
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
        assert_eq!(print_value(json), "{ }");
    }

    #[test]
    fn test_filled_set() {
        let json = json!({"hello": "world"});
        assert_eq!(
            print_value(json),
"{
  hello = \"world\";
}"
        );
    }

   


}
