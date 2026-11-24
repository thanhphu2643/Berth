//! Reads Python literals (what __manifest__.py files are made of) into JSON values:
//! dicts, lists, tuples, strings, numbers, True, False and None.

use serde_json::{Map, Value};

pub fn parse(text: &str) -> Result<Value, String> {
    let mut parser = Parser { chars: text.chars().collect(), at: 0 };
    let value = parser.value()?;
    parser.space();
    if parser.at < parser.chars.len() {
        return Err(format!("unexpected text at character {}", parser.at));
    }
    Ok(value)
}

struct Parser {
    chars: Vec<char>,
    at: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    /// Skips spaces, newlines and # comments.
    fn space(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_whitespace() || c == '\\' {
                self.at += 1;
            } else if c == '#' {
                while self.peek().is_some_and(|c| c != '\n') {
                    self.at += 1;
                }
            } else {
                break;
            }
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        self.space();
        match self.peek().ok_or("unexpected end")? {
            '{' => self.dict(),
            '[' => self.sequence(']'),
            '(' => self.sequence(')'),
            '\'' | '"' => self.strings(),
            c if c.is_ascii_digit() || c == '-' || c == '.' => self.number(),
            c if c.is_alphabetic() || c == '_' => {
                let word = self.word();
                match word.as_str() {
                    "True" => Ok(Value::Bool(true)),
                    "False" => Ok(Value::Bool(false)),
                    "None" => Ok(Value::Null),
                    // String prefixes: r"..", u"..", b"..", rb"..", f".." (kept as plain text).
                    prefix if prefix.len() <= 2 && prefix.chars().all(|c| "rRuUbBfF".contains(c))
                        && matches!(self.peek(), Some('\'' | '"')) => self.strings(),
                    other => Err(format!("unsupported name {other}")),
                }
            }
            c => Err(format!("unexpected {c:?}")),
        }
    }

    fn word(&mut self) -> String {
        let start = self.at;
        while self.peek().is_some_and(|c| c.is_alphanumeric() || c == '_') {
            self.at += 1;
        }
        self.chars[start..self.at].iter().collect()
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.at;
        while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+' | '_')) {
            self.at += 1;
        }
        let text: String = self.chars[start..self.at].iter().filter(|c| **c != '_').collect();
        if let Ok(n) = text.parse::<i64>() {
            return Ok(Value::from(n));
        }
        text.parse::<f64>().map(Value::from).map_err(|_| format!("bad number {text}"))
    }

    /// One string, or several written side by side ("a" "b"), which Python joins.
    fn strings(&mut self) -> Result<Value, String> {
        let mut text = self.string()?;
        loop {
            let save = self.at;
            self.space();
            if matches!(self.peek(), Some('\'' | '"')) {
                text.push_str(&self.string()?);
            } else {
                self.at = save;
                break;
            }
        }
        Ok(Value::String(text))
    }

    fn string(&mut self) -> Result<String, String> {
        let quote = self.peek().ok_or("unexpected end")?;
        let triple = self.chars.get(self.at..self.at + 3) == Some(&[quote, quote, quote][..]);
        self.at += if triple { 3 } else { 1 };
        let mut text = String::new();
        loop {
            let c = self.peek().ok_or("unterminated string")?;
            if c == quote {
                if !triple {
                    self.at += 1;
                    return Ok(text);
                }
                if self.chars.get(self.at..self.at + 3) == Some(&[quote, quote, quote][..]) {
                    self.at += 3;
                    return Ok(text);
                }
            }
            if c == '\n' && !triple {
                return Err("unterminated string".into());
            }
            self.at += 1;
            if c == '\\' {
                let escaped = self.peek().ok_or("unterminated string")?;
                self.at += 1;
                match escaped {
                    'n' => text.push('\n'),
                    't' => text.push('\t'),
                    '\n' => {}
                    other => text.push(other),
                }
            } else {
                text.push(c);
            }
        }
    }

    fn sequence(&mut self, close: char) -> Result<Value, String> {
        self.at += 1;
        let mut items = Vec::new();
        loop {
            self.space();
            if self.peek() == Some(close) {
                self.at += 1;
                return Ok(Value::Array(items));
            }
            items.push(self.value()?);
            self.space();
            match self.peek() {
                Some(',') => self.at += 1,
                Some(c) if c == close => {}
                _ => return Err(format!("expected , or {close}")),
            }
        }
    }

    fn dict(&mut self) -> Result<Value, String> {
        self.at += 1;
        let mut map = Map::new();
        loop {
            self.space();
            if self.peek() == Some('}') {
                self.at += 1;
                return Ok(Value::Object(map));
            }
            let key = match self.value()? {
                Value::String(key) => key,
                other => other.to_string(),
            };
            self.space();
            if self.peek() != Some(':') {
                return Err("expected :".into());
            }
            self.at += 1;
            let value = self.value()?;
            map.insert(key, value);
            self.space();
            match self.peek() {
                Some(',') => self.at += 1,
                Some('}') => {}
                _ => return Err("expected , or }".into()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::parse;
    use serde_json::json;

    #[test]
    fn manifest() {
        let text = r#"# -*- coding: utf-8 -*-
{
    'name': "Sale " 'Extras',  # joined
    "version": '17.0.1.0.0',
    'depends': ['sale', "stock",],
    'data': ('views/a.xml',),
    'installable': True,
    'auto_install': False,
    'sequence': -5,
    'price': 9.5,
    'description': """
Line one
""",
    'assets': {'web.assets_backend': ['x/static/src/**/*']},
    'images': None,
}"#;
        assert_eq!(
            parse(text).unwrap(),
            json!({
                "name": "Sale Extras", "version": "17.0.1.0.0", "depends": ["sale", "stock"],
                "data": ["views/a.xml"], "installable": true, "auto_install": false,
                "sequence": -5, "price": 9.5, "description": "\nLine one\n",
                "assets": {"web.assets_backend": ["x/static/src/**/*"]}, "images": null,
            })
        );
    }

    #[test]
    fn errors() {
        assert!(parse("{'a': open('x')}").is_err());
        assert!(parse("{'a': 'unterminated}").is_err());
    }
}
