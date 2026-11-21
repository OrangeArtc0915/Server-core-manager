//! Excel 公式解析与求值。
//!
//! 支持跨表引用、区域、错误值、比较/连接运算以及常用数学、统计、文本、日期、
//! 查找和财务函数。求值使用递归下降解析器，循环引用返回 `#CYCLE!`。

use std::collections::HashSet;

use super::styles::{date_to_serial, format_number, general_number, serial_to_date};
use super::{Cell, Workbook};

#[derive(Clone, Debug)]
pub enum Value {
    Number(f64),
    Text(String),
    Bool(bool),
    Error(String),
    Empty,
    Range {
        values: Vec<Value>,
        rows: usize,
        cols: usize,
    },
}

impl Value {
    pub fn display(&self) -> String {
        match self {
            Value::Number(value) => general_number(*value),
            Value::Text(text) => text.clone(),
            Value::Bool(value) => if *value { "TRUE" } else { "FALSE" }.to_string(),
            Value::Error(error) => error.clone(),
            Value::Empty => String::new(),
            Value::Range { .. } => "#VALUE!".into(),
        }
    }

    fn scalar(&self) -> Value {
        match self {
            Value::Range { values, .. } => values
                .first()
                .cloned()
                .unwrap_or(Value::Empty),
            other => other.clone(),
        }
    }

    fn number(&self) -> Result<f64, Value> {
        match self {
            Value::Number(value) => Ok(*value),
            Value::Bool(value) => Ok(if *value { 1.0 } else { 0.0 }),
            Value::Empty => Ok(0.0),
            Value::Text(text) => text
                .trim()
                .parse::<f64>()
                .map_err(|_| Value::Error("#VALUE!".into())),
            Value::Error(_) => Err(self.clone()),
            Value::Range { .. } => self.scalar().number(),
        }
    }

    fn text(&self) -> String {
        match self {
            Value::Number(value) => general_number(*value),
            Value::Text(text) => text.clone(),
            Value::Bool(value) => if *value { "TRUE" } else { "FALSE" }.to_string(),
            Value::Empty => String::new(),
            Value::Error(error) => error.clone(),
            Value::Range { .. } => self.scalar().text(),
        }
    }

    fn truthy(&self) -> bool {
        match self {
            Value::Bool(value) => *value,
            Value::Number(value) => *value != 0.0,
            Value::Text(text) => {
                !text.is_empty() && !text.eq_ignore_ascii_case("false") && text != "0"
            }
            Value::Empty => false,
            Value::Error(_) => false,
            Value::Range { .. } => self.scalar().truthy(),
        }
    }

    fn is_error(&self) -> bool {
        matches!(self, Value::Error(_))
    }
}

/// 错误值文本。
pub const ERR_DIV0: &str = "#DIV/0!";
pub const ERR_VALUE: &str = "#VALUE!";
pub const ERR_REF: &str = "#REF!";
pub const ERR_NAME: &str = "#NAME?";
pub const ERR_NA: &str = "#N/A";
pub const ERR_NUM: &str = "#NUM!";
pub const ERR_CYCLE: &str = "#CYCLE!";

pub fn evaluate(
    book: &Workbook,
    sheet: usize,
    formula: &str,
    row: usize,
    col: usize,
    seen: &mut HashSet<(usize, usize, usize)>,
) -> Value {
    let mut parser = Parser {
        chars: formula.chars().collect(),
        pos: 0,
        book,
        sheet,
        origin: (row, col),
        seen,
    };
    parser.compare()
}

struct Parser<'a> {
    chars: Vec<char>,
    pos: usize,
    book: &'a Workbook,
    sheet: usize,
    origin: (usize, usize),
    seen: &'a mut HashSet<(usize, usize, usize)>,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<char> {
        self.chars.get(self.pos + offset).copied()
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.peek();
        if ch.is_some() {
            self.pos += 1;
        }
        ch
    }

    fn skip(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\r' | '\n')) {
            self.pos += 1;
        }
    }

    fn eat(&mut self, ch: char) -> bool {
        self.skip();
        if self.peek() == Some(ch) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn compare(&mut self) -> Value {
        let mut left = self.concat();
        loop {
            self.skip();
            let op = if self.peek() == Some('=') {
                Some("=")
            } else if self.peek() == Some('<') {
                if self.peek_at(1) == Some('>') {
                    Some("<>")
                } else if self.peek_at(1) == Some('=') {
                    Some("<=")
                } else {
                    Some("<")
                }
            } else if self.peek() == Some('>') {
                if self.peek_at(1) == Some('=') {
                    Some(">=")
                } else {
                    Some(">")
                }
            } else {
                None
            };
            let Some(op) = op else {
                break;
            };
            self.pos += op.len();
            let right = self.concat();
            if left.is_error() {
                return left;
            }
            if right.is_error() {
                return right;
            }
            left = Value::Bool(compare_values(&left, &right, op));
        }
        left
    }

    fn concat(&mut self) -> Value {
        let mut left = self.expr();
        while self.eat('&') {
            let right = self.expr();
            if left.is_error() {
                return left;
            }
            if right.is_error() {
                return right;
            }
            left = Value::Text(format!("{}{}", left.text(), right.text()));
        }
        left
    }

    fn expr(&mut self) -> Value {
        let mut left = self.term();
        loop {
            self.skip();
            let op = match self.peek() {
                Some('+') => '+',
                Some('-') => '-',
                _ => break,
            };
            self.pos += 1;
            let right = self.term();
            if left.is_error() {
                return left;
            }
            if right.is_error() {
                return right;
            }
            let result = match (left.number(), right.number()) {
                (Ok(a), Ok(b)) => Ok(if op == '+' { a + b } else { a - b }),
                (Err(error), _) | (_, Err(error)) => Err(error),
            };
            left = match result {
                Ok(value) => Value::Number(value),
                Err(error) => error,
            };
        }
        left
    }

    fn term(&mut self) -> Value {
        let mut left = self.power();
        loop {
            self.skip();
            let op = match self.peek() {
                Some('*') => '*',
                Some('/') => '/',
                _ => break,
            };
            self.pos += 1;
            let right = self.power();
            if left.is_error() {
                return left;
            }
            if right.is_error() {
                return right;
            }
            let value = match (left.number(), right.number()) {
                (Ok(a), Ok(b)) => {
                    if op == '/' {
                        if b == 0.0 {
                            return Value::Error(ERR_DIV0.into());
                        }
                        a / b
                    } else {
                        a * b
                    }
                }
                (Err(error), _) | (_, Err(error)) => return error,
            };
            left = Value::Number(value);
        }
        left
    }

    fn power(&mut self) -> Value {
        let base = self.unary();
        self.skip();
        if self.peek() == Some('^') {
            self.pos += 1;
            let exponent = self.power();
            if base.is_error() {
                return base;
            }
            if exponent.is_error() {
                return exponent;
            }
            return match (base.number(), exponent.number()) {
                (Ok(a), Ok(b)) => Value::Number(a.powf(b)),
                (Err(error), _) | (_, Err(error)) => error,
            };
        }
        base
    }

    fn unary(&mut self) -> Value {
        self.skip();
        match self.peek() {
            Some('-') => {
                self.pos += 1;
                match self.unary().number() {
                    Ok(value) => Value::Number(-value),
                    Err(error) => error,
                }
            }
            Some('+') => {
                self.pos += 1;
                self.unary()
            }
            _ => {
                let value = self.primary();
                if self.peek() == Some('%') {
                    self.pos += 1;
                    match value.number() {
                        Ok(value) => Value::Number(value / 100.0),
                        Err(error) => error,
                    }
                } else {
                    value
                }
            }
        }
    }

    fn primary(&mut self) -> Value {
        self.skip();
        match self.peek() {
            Some('(') => {
                self.pos += 1;
                let value = self.compare();
                self.eat(')');
                value
            }
            Some('"') => {
                self.pos += 1;
                let mut text = String::new();
                while let Some(ch) = self.next() {
                    if ch == '"' {
                        if self.peek() == Some('"') {
                            self.pos += 1;
                            text.push('"');
                        } else {
                            break;
                        }
                    } else {
                        text.push(ch);
                    }
                }
                Value::Text(text)
            }
            Some('#') => {
                let mut error = String::new();
                while let Some(ch) = self.peek() {
                    if ch.is_ascii_alphanumeric()
                        || ch == '/'
                        || ch == '!'
                        || ch == '?'
                        || ch == '.'
                    {
                        error.push(ch);
                        self.pos += 1;
                    } else {
                        break;
                    }
                }
                Value::Error(error)
            }
            Some(ch) if ch.is_ascii_digit() || ch == '.' => {
                let mut text = String::new();
                while let Some(ch) = self.peek() {
                    if ch.is_ascii_digit() || ch == '.' {
                        text.push(ch);
                        self.pos += 1;
                    } else if ch == 'e' || ch == 'E' {
                        text.push(ch);
                        self.pos += 1;
                        if matches!(self.peek(), Some('+' | '-')) {
                            text.push(self.next().unwrap());
                        }
                    } else {
                        break;
                    }
                }
                Value::Number(text.parse().unwrap_or(0.0))
            }
            Some(ch) if ch.is_alphabetic() || ch == '$' || ch == '_' || ch == '\'' => {
                self.reference_or_call()
            }
            _ => Value::Number(0.0),
        }
    }

    fn reference_or_call(&mut self) -> Value {
        self.skip();
        // '工作表名'!引用
        if self.peek() == Some('\'') {
            self.pos += 1;
            let mut sheet_name = String::new();
            while let Some(ch) = self.next() {
                if ch == '\'' {
                    if self.peek() == Some('\'') {
                        self.pos += 1;
                        sheet_name.push('\'');
                    } else {
                        break;
                    }
                } else {
                    sheet_name.push(ch);
                }
            }
            self.skip();
            if self.peek() == Some('!') {
                self.pos += 1;
            }
            return self.reference_after_sheet(Some(sheet_name));
        }
        let mut name = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_alphanumeric() || ch == '$' || ch == '_' || ch == '.' {
                name.push(ch);
                self.pos += 1;
            } else {
                break;
            }
        }
        self.skip();
        if self.peek() == Some('!') {
            self.pos += 1;
            return self.reference_after_sheet(Some(name));
        }
        if self.peek() == Some('(') {
            self.pos += 1;
            return self.call(&name);
        }
        if name.eq_ignore_ascii_case("TRUE") {
            return Value::Bool(true);
        }
        if name.eq_ignore_ascii_case("FALSE") {
            return Value::Bool(false);
        }
        if let Some((row, col)) = parse_ref(&name) {
            return self.finish_reference(self.sheet, row, col);
        }
        Value::Error(ERR_NAME.into())
    }

    fn finish_reference(&mut self, sheet: usize, row: usize, col: usize) -> Value {
        if self.peek() == Some(':') {
            self.pos += 1;
            let mut second = String::new();
            while let Some(ch) = self.peek() {
                if ch.is_ascii_alphanumeric() || ch == '$' {
                    second.push(ch);
                    self.pos += 1;
                } else {
                    break;
                }
            }
            let Some((end_row, end_col)) = parse_ref(&second) else {
                return Value::Error(ERR_REF.into());
            };
            return self.range_value(sheet, row, col, end_row, end_col);
        }
        self.cell_value(sheet, row, col)
    }

    fn reference_after_sheet(&mut self, sheet_name: Option<String>) -> Value {
        let sheet = match sheet_name {
            Some(name) => match self.book.sheet_index(&name) {
                Some(index) => index,
                None => return Value::Error(ERR_REF.into()),
            },
            None => self.sheet,
        };
        let mut first = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphanumeric() || ch == '$' {
                first.push(ch);
                self.pos += 1;
            } else {
                break;
            }
        }
        let Some((row, col)) = parse_ref(&first) else {
            return Value::Error(ERR_REF.into());
        };
        self.finish_reference(sheet, row, col)
    }

    fn call(&mut self, name: &str) -> Value {
        let mut args = Vec::new();
        loop {
            self.skip();
            if self.peek() == Some(')') {
                self.pos += 1;
                break;
            }
            if self.peek().is_none() {
                break;
            }
            args.push(self.compare());
            self.skip();
            match self.peek() {
                Some(',') | Some(';') => {
                    self.pos += 1;
                }
                Some(')') => {
                    self.pos += 1;
                    break;
                }
                _ => break,
            }
        }
        let upper = name.to_ascii_uppercase();
        self.function(&upper, &args)
    }

    fn range_value(
        &mut self,
        sheet: usize,
        row1: usize,
        col1: usize,
        row2: usize,
        col2: usize,
    ) -> Value {
        let mut values = Vec::new();
        let rows = row1.max(row2) - row1.min(row2) + 1;
        let cols = col1.max(col2) - col1.min(col2) + 1;
        for row in row1.min(row2)..=row1.max(row2) {
            for col in col1.min(col2)..=col1.max(col2) {
                values.push(self.cell_value(sheet, row, col));
            }
        }
        Value::Range { values, rows, cols }
    }

    fn cell_value(&mut self, sheet: usize, row: usize, col: usize) -> Value {
        let Some(target) = self.book.sheets.get(sheet) else {
            return Value::Error(ERR_REF.into());
        };
        let Some(cell) = target.cells.get(&(row, col)) else {
            return Value::Empty;
        };
        if let Some(formula) = &cell.formula {
            if !self.seen.insert((sheet, row, col)) {
                return Value::Error(ERR_CYCLE.into());
            }
            let value = evaluate(self.book, sheet, formula, row, col, self.seen);
            self.seen.remove(&(sheet, row, col));
            return value;
        }
        text_to_value(&cell.text)
    }

    fn function(&mut self, name: &str, args: &[Value]) -> Value {
        let numbers = numeric_args(args);
        match name {
            "SUM" => number_sum(&numbers),
            "PRODUCT" => {
                if numbers.is_empty() {
                    Value::Number(0.0)
                } else {
                    Value::Number(numbers.iter().product())
                }
            }
            "AVERAGE" => {
                if numbers.is_empty() {
                    Value::Error(ERR_DIV0.into())
                } else {
                    Value::Number(numbers.iter().sum::<f64>() / numbers.len() as f64)
                }
            }
            "MIN" => {
                if numbers.is_empty() {
                    Value::Number(0.0)
                } else {
                    Value::Number(numbers.iter().cloned().fold(f64::INFINITY, f64::min))
                }
            }
            "MAX" => {
                if numbers.is_empty() {
                    Value::Number(0.0)
                } else {
                    Value::Number(numbers.iter().cloned().fold(f64::NEG_INFINITY, f64::max))
                }
            }
            "COUNT" => Value::Number(numbers.len() as f64),
            "COUNTA" => Value::Number(
                flat(args)
                    .iter()
                    .filter(|value| !matches!(value, Value::Empty))
                    .count() as f64,
            ),
            "COUNTBLANK" => Value::Number(
                flat(args)
                    .iter()
                    .filter(|value| matches!(value, Value::Empty))
                    .count() as f64,
            ),
            "ABS" => unary_number(args, f64::abs),
            "SIGN" => Value::Number(args.first().and_then(|v| v.number().ok()).map(f64::signum).unwrap_or(0.0)),
            "SQRT" => {
                let value = arg_number(args, 0);
                if value < 0.0 {
                    Value::Error(ERR_NUM.into())
                } else {
                    Value::Number(value.sqrt())
                }
            }
            "POWER" => Value::Number(arg_number(args, 0).powf(arg_number(args, 1))),
            "EXP" => Value::Number(arg_number(args, 0).exp()),
            "LN" => Value::Number(arg_number(args, 0).ln()),
            "LOG" => {
                let value = arg_number(args, 0);
                let base = if args.len() > 1 { arg_number(args, 1) } else { 10.0 };
                Value::Number(value.log(base))
            }
            "LOG10" => Value::Number(arg_number(args, 0).log10()),
            "PI" => Value::Number(std::f64::consts::PI),
            "SIN" => Value::Number(arg_number(args, 0).sin()),
            "COS" => Value::Number(arg_number(args, 0).cos()),
            "TAN" => Value::Number(arg_number(args, 0).tan()),
            "ASIN" => Value::Number(arg_number(args, 0).asin()),
            "ACOS" => Value::Number(arg_number(args, 0).acos()),
            "ATAN" => Value::Number(arg_number(args, 0).atan()),
            "ATAN2" => Value::Number(arg_number(args, 0).atan2(arg_number(args, 1))),
            "DEGREES" => Value::Number(arg_number(args, 0).to_degrees()),
            "RADIANS" => Value::Number(arg_number(args, 0).to_radians()),
            "ROUND" => Value::Number(round_digits(arg_number(args, 0), arg_number(args, 1) as i32, false)),
            "ROUNDUP" => Value::Number(round_digits(arg_number(args, 0), arg_number(args, 1) as i32, true)),
            "ROUNDDOWN" => {
                let factor = 10f64.powi(arg_number(args, 1) as i32);
                Value::Number((arg_number(args, 0) * factor).trunc() / factor)
            }
            "INT" => Value::Number(arg_number(args, 0).floor()),
            "TRUNC" => {
                let digits = if args.len() > 1 { arg_number(args, 1) as i32 } else { 0 };
                let factor = 10f64.powi(digits);
                Value::Number((arg_number(args, 0) * factor).trunc() / factor)
            }
            "MOD" => {
                let a = arg_number(args, 0);
                let b = arg_number(args, 1);
                if b == 0.0 {
                    Value::Error(ERR_DIV0.into())
                } else {
                    Value::Number(a - b * (a / b).floor())
                }
            }
            "CEILING" => {
                let value = arg_number(args, 0);
                let significance = if args.len() > 1 { arg_number(args, 1) } else { 1.0 };
                if significance == 0.0 {
                    Value::Number(0.0)
                } else {
                    Value::Number((value / significance).ceil() * significance)
                }
            }
            "FLOOR" => {
                let value = arg_number(args, 0);
                let significance = if args.len() > 1 { arg_number(args, 1) } else { 1.0 };
                if significance == 0.0 {
                    Value::Number(0.0)
                } else {
                    Value::Number((value / significance).floor() * significance)
                }
            }
            "RAND" => Value::Number(random_fraction()),
            "RANDBETWEEN" => {
                let low = arg_number(args, 0).ceil();
                let high = arg_number(args, 1).floor();
                if high < low {
                    Value::Error(ERR_NUM.into())
                } else {
                    Value::Number(low + (random_fraction() * (high - low + 1.0)).floor())
                }
            }
            "GCD" => {
                let mut value = 0i64;
                for number in &numbers {
                    value = gcd(value, number.abs() as i64);
                }
                Value::Number(value as f64)
            }
            "LCM" => {
                let mut value = 1i64;
                for number in &numbers {
                    let number = number.abs() as i64;
                    if number == 0 {
                        return Value::Number(0.0);
                    }
                    value = value / gcd(value, number) * number;
                }
                Value::Number(value as f64)
            }
            "FACT" => {
                let n = arg_number(args, 0).floor().max(0.0) as u64;
                let mut value = 1u64;
                for index in 2..=n.min(20) {
                    value = value.saturating_mul(index);
                }
                Value::Number(value as f64)
            }
            "SUMIF" => self.sum_if(args),
            "SUMIFS" => self.sum_ifs(args, false),
            "AVERAGEIF" => {
                let range = args.first().cloned().unwrap_or(Value::Empty);
                let criteria = args.get(1).cloned().unwrap_or(Value::Empty);
                let average = args.get(2).cloned().unwrap_or_else(|| range.clone());
                self.sum_ifs(&[average, range, criteria], true)
            }
            "AVERAGEIFS" => self.sum_ifs(args, true),
            "COUNTIF" => self.count_if(args, 1),
            "COUNTIFS" => self.count_ifs(args),
            "MEDIAN" => {
                let mut values = numbers.clone();
                values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                if values.is_empty() {
                    Value::Error(ERR_NUM.into())
                } else if values.len() % 2 == 0 {
                    let mid = values.len() / 2;
                    Value::Number((values[mid - 1] + values[mid]) / 2.0)
                } else {
                    Value::Number(values[values.len() / 2])
                }
            }
            "LARGE" | "SMALL" => {
                let mut values = numbers.clone();
                values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                let index = arg_number(args, 1) as usize;
                if index == 0 || index > values.len() {
                    Value::Error(ERR_NUM.into())
                } else if name == "LARGE" {
                    Value::Number(values[values.len() - index])
                } else {
                    Value::Number(values[index - 1])
                }
            }
            "STDEV" | "STDEVP" | "VAR" | "VARP" => {
                if numbers.is_empty() {
                    return Value::Error(ERR_DIV0.into());
                }
                let mean = numbers.iter().sum::<f64>() / numbers.len() as f64;
                let sum: f64 = numbers.iter().map(|value| (value - mean).powi(2)).sum();
                let population = name.ends_with('P');
                let divisor = if population {
                    numbers.len() as f64
                } else if numbers.len() > 1 {
                    (numbers.len() - 1) as f64
                } else {
                    return Value::Error(ERR_DIV0.into());
                };
                let variance = sum / divisor;
                if name.starts_with("STDEV") {
                    Value::Number(variance.sqrt())
                } else {
                    Value::Number(variance)
                }
            }
            "SUMPRODUCT" => {
                let arrays: Vec<&Vec<Value>> = args
                    .iter()
                    .filter_map(|value| match value {
                        Value::Range { values, .. } => Some(values),
                        _ => None,
                    })
                    .collect();
                if arrays.is_empty() {
                    Value::Number(0.0)
                } else {
                    let len = arrays.iter().map(|array| array.len()).min().unwrap_or(0);
                    let mut total = 0.0;
                    for index in 0..len {
                        let mut product = 1.0;
                        for array in &arrays {
                            product *= value_number(&array[index]);
                        }
                        total += product;
                    }
                    Value::Number(total)
                }
            }
            "RANK" => {
                let value = arg_number(args, 0);
                let values = match args.get(1) {
                    Some(Value::Range { values, .. }) => values.clone(),
                    _ => Vec::new(),
                };
                let mut numbers: Vec<f64> = values
                    .iter()
                    .filter_map(|item| item.number().ok())
                    .collect();
                numbers.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
                let ascending = args.get(2).map(|item| item.truthy()).unwrap_or(false);
                if ascending {
                    numbers.reverse();
                }
                Value::Number(
                    numbers
                        .iter()
                        .position(|item| (*item - value).abs() < 1e-12)
                        .map(|index| index + 1)
                        .unwrap_or(0) as f64,
                )
            }
            "IF" => {
                if !args.first().map(|v| v.truthy()).unwrap_or(false) {
                    args.get(2).cloned().unwrap_or(Value::Bool(false))
                } else {
                    args.get(1).cloned().unwrap_or(Value::Bool(true))
                }
            }
            "IFERROR" => {
                let value = args.first().cloned().unwrap_or(Value::Empty);
                if matches!(value, Value::Error(_)) {
                    args.get(1).cloned().unwrap_or(Value::Empty)
                } else {
                    value
                }
            }
            "IFNA" => {
                let value = args.first().cloned().unwrap_or(Value::Empty);
                if matches!(&value, Value::Error(error) if error == ERR_NA) {
                    args.get(1).cloned().unwrap_or(Value::Empty)
                } else {
                    value
                }
            }
            "AND" => {
                let mut result = true;
                for value in flat(args) {
                    if matches!(value, Value::Error(_)) {
                        return value.clone();
                    }
                    if !matches!(value, Value::Empty) {
                        result &= value.truthy();
                    }
                }
                Value::Bool(result)
            }
            "OR" => {
                let mut result = false;
                for value in flat(args) {
                    if matches!(value, Value::Error(_)) {
                        return value.clone();
                    }
                    if !matches!(value, Value::Empty) {
                        result |= value.truthy();
                    }
                }
                Value::Bool(result)
            }
            "NOT" => Value::Bool(!args.first().map(|v| v.truthy()).unwrap_or(false)),
            "XOR" => {
                let mut result = false;
                for value in flat(args) {
                    result ^= value.truthy();
                }
                Value::Bool(result)
            }
            "TRUE" => Value::Bool(true),
            "FALSE" => Value::Bool(false),
            "NA" => Value::Error(ERR_NA.into()),
            "N" => {
                let value = args.first().cloned().unwrap_or(Value::Empty);
                match value {
                    Value::Number(_) => value,
                    Value::Bool(value) => Value::Number(if value { 1.0 } else { 0.0 }),
                    _ => Value::Number(0.0),
                }
            }
            "ISBLANK" => Value::Bool(matches!(args.first(), Some(Value::Empty) | None)),
            "ISNUMBER" => Value::Bool(matches!(args.first(), Some(Value::Number(_)))),
            "ISTEXT" => Value::Bool(matches!(args.first(), Some(Value::Text(_)))),
            "ISERROR" => Value::Bool(args.first().map(|v| v.is_error()).unwrap_or(false)),
            "ISERR" => Value::Bool(
                args.first()
                    .map(|v| matches!(v, Value::Error(error) if error != ERR_NA))
                    .unwrap_or(false),
            ),
            "ISNA" => Value::Bool(matches!(args.first(), Some(Value::Error(error)) if error == ERR_NA)),
            "CONCAT" | "CONCATENATE" => {
                Value::Text(flat(args).iter().map(|value| value.text()).collect())
            }
            "LEFT" => {
                let count = if args.len() > 1 { arg_number(args, 1) as usize } else { 1 };
                Value::Text(args.first().map(|v| v.text()).unwrap_or_default().chars().take(count).collect())
            }
            "RIGHT" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                let count = if args.len() > 1 { arg_number(args, 1) as usize } else { 1 };
                let chars: Vec<char> = text.chars().collect();
                let start = chars.len().saturating_sub(count);
                Value::Text(chars[start..].iter().collect())
            }
            "MID" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                let start = arg_number(args, 1).max(0.0) as usize;
                let count = arg_number(args, 2).max(0.0) as usize;
                Value::Text(text.chars().skip(start.saturating_sub(1)).take(count).collect())
            }
            "LEN" => Value::Number(args.first().map(|v| v.text()).unwrap_or_default().chars().count() as f64),
            "LOWER" => Value::Text(args.first().map(|v| v.text()).unwrap_or_default().to_lowercase()),
            "UPPER" => Value::Text(args.first().map(|v| v.text()).unwrap_or_default().to_uppercase()),
            "PROPER" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                Value::Text(
                    text.split(' ')
                        .map(|word| {
                            let mut chars = word.chars();
                            match chars.next() {
                                Some(first) => format!(
                                    "{}{}",
                                    first.to_uppercase(),
                                    chars.as_str().to_lowercase()
                                ),
                                None => String::new(),
                            }
                        })
                        .collect::<Vec<_>>()
                        .join(" "),
                )
            }
            "TRIM" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                Value::Text(text.split_whitespace().collect::<Vec<_>>().join(" "))
            }
            "SUBSTITUTE" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                let old = args.get(1).map(|v| v.text()).unwrap_or_default();
                let new = args.get(2).map(|v| v.text()).unwrap_or_default();
                Value::Text(text.replace(&old, &new))
            }
            "REPLACE" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                let start = arg_number(args, 1).max(1.0) as usize;
                let count = arg_number(args, 2).max(0.0) as usize;
                let new = args.get(3).map(|v| v.text()).unwrap_or_default();
                let chars: Vec<char> = text.chars().collect();
                let mut out: String = chars.iter().take(start - 1).collect();
                out.push_str(&new);
                out.extend(chars.iter().skip((start - 1 + count).min(chars.len())));
                Value::Text(out)
            }
            "FIND" | "SEARCH" => {
                let needle = args.first().map(|v| v.text()).unwrap_or_default();
                let haystack = args.get(1).map(|v| v.text()).unwrap_or_default();
                let start = args.get(2).map(|v| value_number(v) as usize).unwrap_or(1).max(1);
                let offset: usize = haystack.chars().take(start - 1).map(|ch| ch.len_utf8()).sum();
                let (needle, haystack_part) = if name == "SEARCH" {
                    (needle.to_lowercase(), haystack[offset..].to_lowercase())
                } else {
                    (needle.clone(), haystack[offset..].to_string())
                };
                match haystack_part.find(&needle) {
                    Some(index) => {
                        let prefix_len = haystack[offset..offset + index].chars().count();
                        Value::Number((start + prefix_len) as f64)
                    }
                    None => Value::Error(ERR_VALUE.into()),
                }
            }
            "REPT" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                let count = arg_number(args, 1).max(0.0) as usize;
                Value::Text(text.repeat(count.min(10000)))
            }
            "CHAR" => Value::Text(
                char::from_u32(arg_number(args, 0).max(0.0) as u32)
                    .unwrap_or(' ')
                    .to_string(),
            ),
            "CODE" => Value::Number(
                args.first()
                    .map(|v| v.text().chars().next().map(|ch| ch as u32).unwrap_or(0))
                    .unwrap_or(0) as f64,
            ),
            "EXACT" => Value::Bool(
                args.first().map(|v| v.text()).unwrap_or_default()
                    == args.get(1).map(|v| v.text()).unwrap_or_default(),
            ),
            "T" => match args.first() {
                Some(Value::Text(text)) => Value::Text(text.clone()),
                _ => Value::Text(String::new()),
            },
            "VALUE" => {
                let text = args.first().map(|v| v.text()).unwrap_or_default();
                match text.trim().parse::<f64>() {
                    Ok(value) => Value::Number(value),
                    Err(_) => Value::Error(ERR_VALUE.into()),
                }
            }
            "TEXT" => {
                let value = arg_number(args, 0);
                let format = args.get(1).map(|v| v.text()).unwrap_or_default();
                Value::Text(format_number(value, &format, self.book.date1904))
            }
            "TODAY" => Value::Number(today_serial(self.book.date1904)),
            "NOW" => Value::Number(today_serial(self.book.date1904) + current_fraction()),
            "DATE" => Value::Number(date_to_serial(
                arg_number(args, 0) as i32,
                arg_number(args, 1).max(1.0) as u32,
                arg_number(args, 2).max(1.0) as u32,
                self.book.date1904,
            )),
            "TIME" => Value::Number(
                (arg_number(args, 0) * 3600.0 + arg_number(args, 1) * 60.0 + arg_number(args, 2))
                    / 86400.0,
            ),
            "YEAR" | "MONTH" | "DAY" | "HOUR" | "MINUTE" | "SECOND" => {
                let (year, month, day, hour, minute, second) =
                    serial_to_date(arg_number(args, 0), self.book.date1904);
                Value::Number(match name {
                    "YEAR" => year as f64,
                    "MONTH" => month as f64,
                    "DAY" => day as f64,
                    "HOUR" => hour as f64,
                    "MINUTE" => minute as f64,
                    _ => second as f64,
                })
            }
            "WEEKDAY" => {
                let (year, month, day, _, _, _) =
                    serial_to_date(arg_number(args, 0), self.book.date1904);
                let serial = date_to_serial(year, month, day, false);
                Value::Number((serial % 7.0 + 1.0).max(1.0))
            }
            "EDATE" | "EOMONTH" => {
                let serial = arg_number(args, 0);
                let months = arg_number(args, 1) as i32;
                let (year, month, day, _, _, _) = serial_to_date(serial, self.book.date1904);
                let total = year * 12 + month as i32 - 1 + months;
                let new_year = total.div_euclid(12);
                let new_month = total.rem_euclid(12) as u32 + 1;
                let max_day = days_in_month(new_year, new_month);
                let new_day = if name == "EOMONTH" {
                    max_day
                } else {
                    day.min(max_day)
                };
                Value::Number(date_to_serial(
                    new_year,
                    new_month,
                    new_day,
                    self.book.date1904,
                ))
            }
            "DAYS" => Value::Number(arg_number(args, 0) - arg_number(args, 1)),
            "DATEDIF" => {
                let start = serial_to_date(arg_number(args, 0), self.book.date1904);
                let end = serial_to_date(arg_number(args, 1), self.book.date1904);
                let unit = args.get(2).map(|v| v.text().to_ascii_uppercase()).unwrap_or_default();
                let mut months = (end.0 - start.0) * 12 + end.1 as i32 - start.1 as i32;
                if end.2 < start.2 {
                    months -= 1;
                }
                Value::Number(match unit.as_str() {
                    "Y" => (months / 12) as f64,
                    "M" => months as f64,
                    "D" => arg_number(args, 1) - arg_number(args, 0),
                    "YM" => (months % 12) as f64,
                    _ => 0.0,
                })
            }
            "VLOOKUP" | "HLOOKUP" => {
                let lookup = args.first().cloned().unwrap_or(Value::Empty);
                let (values, rows, cols) = match args.get(1) {
                    Some(Value::Range { values, rows, cols }) => {
                        (values.clone(), *rows, *cols)
                    }
                    _ => (Vec::new(), 0, 0),
                };
                let index = arg_number(args, 2).max(1.0) as usize;
                let approximate = args.get(3).map(|v| v.truthy()).unwrap_or(true);
                if values.is_empty() {
                    return Value::Error(ERR_REF.into());
                }
                let mut found = None;
                if name == "VLOOKUP" {
                    if index > cols {
                        return Value::Error(ERR_REF.into());
                    }
                    for row in 0..rows {
                        let candidate = &values[row * cols];
                        if matches_value(candidate, &lookup, approximate, row == 0) {
                            found = Some(row);
                        } else if approximate && !matches_value(candidate, &lookup, true, row == 0) {
                            break;
                        }
                    }
                    found
                        .map(|row| values[row * cols + index - 1].clone())
                        .unwrap_or(Value::Error(ERR_NA.into()))
                } else {
                    if index > rows {
                        return Value::Error(ERR_REF.into());
                    }
                    for col in 0..cols {
                        let candidate = &values[col];
                        if matches_value(candidate, &lookup, approximate, col == 0) {
                            found = Some(col);
                        } else if approximate && !matches_value(candidate, &lookup, true, col == 0) {
                            break;
                        }
                    }
                    found
                        .map(|col| values[(index - 1) * cols + col].clone())
                        .unwrap_or(Value::Error(ERR_NA.into()))
                }
            }
            "MATCH" => {
                let lookup = args.first().cloned().unwrap_or(Value::Empty);
                let values = match args.get(1) {
                    Some(Value::Range { values, .. }) => values.clone(),
                    _ => Vec::new(),
                };
                let mode = args.get(2).map(|v| value_number(v) as i32).unwrap_or(1);
                let mut found = 0;
                for (index, candidate) in values.iter().enumerate() {
                    if matches_value(candidate, &lookup, mode != 0, index == 0) {
                        found = index + 1;
                    }
                }
                if found > 0 {
                    Value::Number(found as f64)
                } else {
                    Value::Error(ERR_NA.into())
                }
            }
            "INDEX" => {
                let (values, rows, cols) = match args.first() {
                    Some(Value::Range { values, rows, cols }) => (values.clone(), *rows, *cols),
                    _ => (Vec::new(), 0, 0),
                };
                if values.is_empty() {
                    return Value::Error(ERR_REF.into());
                }
                let row = arg_number(args, 1).max(1.0) as usize;
                let col = args.get(2).map(|v| value_number(v).max(1.0) as usize).unwrap_or(1);
                if row > rows || col > cols {
                    Value::Error(ERR_REF.into())
                } else {
                    values[(row - 1) * cols + col - 1].clone()
                }
            }
            "CHOOSE" => {
                let index = arg_number(args, 0).max(1.0) as usize;
                args.get(index).cloned().unwrap_or(Value::Error(ERR_VALUE.into()))
            }
            "ROWS" => Value::Number(match args.first() {
                Some(Value::Range { rows, .. }) => *rows as f64,
                _ => 1.0,
            }),
            "COLUMNS" => Value::Number(match args.first() {
                Some(Value::Range { cols, .. }) => *cols as f64,
                _ => 1.0,
            }),
            "ROW" => Value::Number(
                args.first()
                    .and_then(|value| match value {
                        Value::Range { values, .. } => values.first().map(|_| 1.0),
                        _ => None,
                    })
                    .unwrap_or((self.origin.0 + 1) as f64),
            ),
            "COLUMN" => Value::Number((self.origin.1 + 1) as f64),
            "INDIRECT" => {
                let reference = args.first().map(|v| v.text()).unwrap_or_default();
                let mut sub = Parser {
                    chars: reference.chars().collect(),
                    pos: 0,
                    book: self.book,
                    sheet: self.sheet,
                    origin: self.origin,
                    seen: self.seen,
                };
                sub.compare()
            }
            "PMT" => {
                let rate = arg_number(args, 0);
                let periods = arg_number(args, 1);
                let present = arg_number(args, 2);
                let future = args.get(3).map(|v| value_number(v)).unwrap_or(0.0);
                if rate == 0.0 {
                    Value::Number(-(present + future) / periods)
                } else {
                    let factor = (1.0 + rate).powf(periods);
                    Value::Number(-(present * factor + future) * rate / (factor - 1.0))
                }
            }
            "FV" => {
                let rate = arg_number(args, 0);
                let periods = arg_number(args, 1);
                let payment = arg_number(args, 2);
                let present = args.get(3).map(|v| value_number(v)).unwrap_or(0.0);
                if rate == 0.0 {
                    Value::Number(-(present + payment * periods))
                } else {
                    let factor = (1.0 + rate).powf(periods);
                    Value::Number(-(present * factor + payment * (factor - 1.0) / rate))
                }
            }
            "PV" => {
                let rate = arg_number(args, 0);
                let periods = arg_number(args, 1);
                let payment = arg_number(args, 2);
                let future = args.get(3).map(|v| value_number(v)).unwrap_or(0.0);
                if rate == 0.0 {
                    Value::Number(-payment * periods - future)
                } else {
                    let factor = (1.0 + rate).powf(periods);
                    Value::Number(-(payment * (factor - 1.0) / rate + future) / factor)
                }
            }
            "NPV" => {
                let rate = arg_number(args, 0);
                let mut total = 0.0;
                let mut index = 1;
                for value in args.iter().skip(1) {
                    let values = match value {
                        Value::Range { values, .. } => values.clone(),
                        other => vec![other.clone()],
                    };
                    for item in values {
                        total += value_number(&item) / (1.0 + rate).powi(index);
                        index += 1;
                    }
                }
                Value::Number(total)
            }
            _ => Value::Error(ERR_NAME.into()),
        }
    }

    fn sum_if(&mut self, args: &[Value]) -> Value {
        let range = match args.first() {
            Some(Value::Range { values, .. }) => values.clone(),
            _ => return Value::Error(ERR_VALUE.into()),
        };
        let criteria = args.get(1).map(|v| v.text()).unwrap_or_default();
        let sum_values = match args.get(2) {
            Some(Value::Range { values, .. }) => values.clone(),
            _ => range.clone(),
        };
        let mut total = 0.0;
        for (index, value) in range.iter().enumerate() {
            if criteria_matches(value, &criteria) {
                total += sum_values
                    .get(index)
                    .and_then(|item| item.number().ok())
                    .unwrap_or(0.0);
            }
        }
        Value::Number(total)
    }

    fn count_if(&mut self, args: &[Value], _kind: usize) -> Value {
        let range = match args.first() {
            Some(Value::Range { values, .. }) => values.clone(),
            _ => return Value::Error(ERR_VALUE.into()),
        };
        let criteria = args.get(1).map(|v| v.text()).unwrap_or_default();
        Value::Number(
            range
                .iter()
                .filter(|value| criteria_matches(value, &criteria))
                .count() as f64,
        )
    }

    fn count_ifs(&mut self, args: &[Value]) -> Value {
        if args.len() < 2 {
            return Value::Error(ERR_VALUE.into());
        }
        let first = match &args[0] {
            Value::Range { values, .. } => values.clone(),
            _ => return Value::Error(ERR_VALUE.into()),
        };
        let mut count = 0;
        for index in 0..first.len() {
            let mut matched = true;
            let mut offset = 0;
            while offset + 1 < args.len() {
                let values = match &args[offset] {
                    Value::Range { values, .. } => values,
                    _ => return Value::Error(ERR_VALUE.into()),
                };
                let criteria = args[offset + 1].text();
                if !values
                    .get(index)
                    .map(|value| criteria_matches(value, &criteria))
                    .unwrap_or(false)
                {
                    matched = false;
                    break;
                }
                offset += 2;
            }
            if matched {
                count += 1;
            }
        }
        Value::Number(count as f64)
    }

    fn sum_ifs(&mut self, args: &[Value], average: bool) -> Value {
        if args.len() < 3 {
            return Value::Error(ERR_VALUE.into());
        }
        let sum_range = match &args[0] {
            Value::Range { values, .. } => values.clone(),
            _ => return Value::Error(ERR_VALUE.into()),
        };
        let mut total = 0.0;
        let mut count = 0;
        for index in 0..sum_range.len() {
            let mut matched = true;
            let mut offset = 1;
            while offset + 1 < args.len() {
                let values = match &args[offset] {
                    Value::Range { values, .. } => values,
                    _ => return Value::Error(ERR_VALUE.into()),
                };
                let criteria = args[offset + 1].text();
                if !values
                    .get(index)
                    .map(|value| criteria_matches(value, &criteria))
                    .unwrap_or(false)
                {
                    matched = false;
                    break;
                }
                offset += 2;
            }
            if matched {
                total += sum_range
                    .get(index)
                    .and_then(|item| item.number().ok())
                    .unwrap_or(0.0);
                count += 1;
            }
        }
        if average {
            if count == 0 {
                Value::Error(ERR_DIV0.into())
            } else {
                Value::Number(total / count as f64)
            }
        } else {
            Value::Number(total)
        }
    }
}

pub(crate) fn text_to_value(text: &str) -> Value {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Empty;
    }
    if trimmed.eq_ignore_ascii_case("true") {
        return Value::Bool(true);
    }
    if trimmed.eq_ignore_ascii_case("false") {
        return Value::Bool(false);
    }
    if let Ok(number) = trimmed.parse::<f64>() {
        return Value::Number(number);
    }
    Value::Text(text.to_string())
}

fn parse_ref(reference: &str) -> Option<(usize, usize)> {
    let mut col = 0usize;
    let mut row = 0usize;
    let mut seen_row = false;
    let mut has_col = false;
    for ch in reference.chars() {
        if ch == '$' {
            continue;
        }
        if ch.is_ascii_alphabetic() {
            if seen_row {
                return None;
            }
            col = col * 26 + (ch.to_ascii_uppercase() as usize - 'A' as usize + 1);
            has_col = true;
        } else if ch.is_ascii_digit() {
            seen_row = true;
            row = row * 10 + (ch as usize - '0' as usize);
        } else {
            return None;
        }
    }
    if !has_col || row == 0 {
        return None;
    }
    Some((row - 1, col - 1))
}

fn flat(args: &[Value]) -> Vec<Value> {
    let mut out = Vec::new();
    for arg in args {
        match arg {
            Value::Range { values, .. } => {
                for value in values {
                    match value {
                        Value::Range { .. } => {}
                        other => out.push(other.clone()),
                    }
                }
            }
            other => out.push(other.clone()),
        }
    }
    out
}

fn numeric_args(args: &[Value]) -> Vec<f64> {
    let mut out = Vec::new();
    for arg in args {
        match arg {
            Value::Range { values, .. } => {
                for value in values {
                    if let Ok(number) = value.number() {
                        if !matches!(value, Value::Empty | Value::Bool(_)) {
                            out.push(number);
                        }
                    }
                }
            }
            other => {
                if let Ok(number) = other.number() {
                    out.push(number);
                }
            }
        }
    }
    out
}

fn arg_number(args: &[Value], index: usize) -> f64 {
    args.get(index).map(value_number).unwrap_or(0.0)
}

fn value_number(value: &Value) -> f64 {
    value.number().unwrap_or(0.0)
}

fn unary_number(args: &[Value], function: fn(f64) -> f64) -> Value {
    Value::Number(function(arg_number(args, 0)))
}

fn number_sum(numbers: &[f64]) -> Value {
    Value::Number(numbers.iter().sum())
}

fn round_digits(value: f64, digits: i32, up: bool) -> f64 {
    let factor = 10f64.powi(digits);
    if up {
        (value * factor).abs().ceil().copysign(value) / factor
    } else {
        (value * factor).round() / factor
    }
}

fn compare_values(left: &Value, right: &Value, operation: &str) -> bool {
    let ordering = match (left, right) {
        (Value::Text(a), Value::Text(b)) => a.to_lowercase().cmp(&b.to_lowercase()),
        (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
        _ => {
            let a = value_number(left);
            let b = value_number(right);
            a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
        }
    };
    match operation {
        "=" => ordering == std::cmp::Ordering::Equal,
        "<>" => ordering != std::cmp::Ordering::Equal,
        "<" => ordering == std::cmp::Ordering::Less,
        "<=" => ordering != std::cmp::Ordering::Greater,
        ">" => ordering == std::cmp::Ordering::Greater,
        ">=" => ordering != std::cmp::Ordering::Less,
        _ => false,
    }
}

fn matches_value(candidate: &Value, lookup: &Value, approximate: bool, _first: bool) -> bool {
    if !approximate {
        return compare_values(candidate, lookup, "=");
    }
    match (candidate, lookup) {
        (Value::Text(a), Value::Text(b)) => a.to_lowercase() <= b.to_lowercase(),
        _ => value_number(candidate) <= value_number(lookup),
    }
}

pub(crate) fn criteria_matches(value: &Value, criteria: &str) -> bool {
    let criteria = criteria.trim();
    if criteria.is_empty() {
        return matches!(value, Value::Empty);
    }
    for (op, _rest) in [
        (">=", ">="),
        ("<=", "<="),
        ("<>", "<>"),
        (">", ">"),
        ("<", "<"),
        ("=", "="),
    ] {
        if let Some(rest) = criteria.strip_prefix(op) {
            let rest = rest.trim();
            let target = if let Ok(number) = rest.parse::<f64>() {
                Value::Number(number)
            } else {
                Value::Text(rest.to_string())
            };
            return compare_values(value, &target, rest_op(op));
        }
    }
    if criteria.contains('*') || criteria.contains('?') || criteria.contains('~') {
        return wildcard_match(&value.text(), criteria);
    }
    if let Ok(number) = criteria.parse::<f64>() {
        return (value_number(value) - number).abs() < 1e-12
            && !matches!(value, Value::Text(_));
    }
    value.text().eq_ignore_ascii_case(criteria)
}

fn rest_op(op: &str) -> &str {
    op
}

fn wildcard_match(text: &str, pattern: &str) -> bool {
    let text: Vec<char> = text.to_lowercase().chars().collect();
    let pattern: Vec<char> = pattern.to_lowercase().chars().collect();
    fn matches(text: &[char], pattern: &[char]) -> bool {
        if pattern.is_empty() {
            return text.is_empty();
        }
        match pattern[0] {
            '*' => {
                (0..=text.len()).any(|index| matches(&text[index..], &pattern[1..]))
            }
            '?' => !text.is_empty() && matches(&text[1..], &pattern[1..]),
            '~' => {
                if pattern.len() > 1 {
                    !text.is_empty()
                        && text[0] == pattern[1]
                        && matches(&text[1..], &pattern[2..])
                } else {
                    false
                }
            }
            ch => !text.is_empty() && text[0] == ch && matches(&text[1..], &pattern[1..]),
        }
    }
    matches(&text, &pattern)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a.abs()
    } else {
        gcd(b, a % b)
    }
}

fn random_fraction() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.subsec_nanos())
        .unwrap_or(0);
    (nanos as f64 % 1_000_000.0) / 1_000_000.0
}

fn today_serial(date1904: bool) -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let days = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() / 86400)
        .unwrap_or(0) as f64;
    date_to_serial(1970, 1, 1, date1904) + days
}

fn current_fraction() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| (value.as_secs() % 86400) as f64 / 86400.0)
        .unwrap_or(0.0)
}

/// 单元格显示值：数字按样式格式，文本原样。
pub fn display_cell(_cell: &Cell, style_format: &str, date1904: bool, value: Value) -> String {
    match value {
        Value::Number(number) => format_number(number, style_format, date1904),
        Value::Empty => String::new(),
        other => other.display(),
    }
}
