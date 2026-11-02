// A small JSON value: enough for the dial's line protocol. Parses and
// serializes objects, arrays, strings (UTF-8, with \u escapes), numbers,
// booleans and null.
#pragma once
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace json {

struct Value;
using Object = std::map<std::string, Value>;
using Array = std::vector<Value>;

struct Value {
    enum Kind { Null, Bool, Number, String, ArrayKind, ObjectKind } kind = Null;
    bool b = false;
    double n = 0;
    std::string s;
    std::shared_ptr<Array> a;
    std::shared_ptr<Object> o;

    Value() {}
    Value(bool v) : kind(Bool), b(v) {}
    Value(int v) : kind(Number), n(v) {}
    Value(double v) : kind(Number), n(v) {}
    Value(const char* v) : kind(String), s(v) {}
    Value(const std::string& v) : kind(String), s(v) {}
    Value(const Array& v) : kind(ArrayKind), a(std::make_shared<Array>(v)) {}
    Value(const Object& v) : kind(ObjectKind), o(std::make_shared<Object>(v)) {}

    bool isNull() const { return kind == Null; }
    bool isString() const { return kind == String; }
    bool isObject() const { return kind == ObjectKind; }
    bool isArray() const { return kind == ArrayKind; }

    const Value& operator[](const char* key) const {
        static const Value none;
        if (kind != ObjectKind) return none;
        auto it = o->find(key);
        return it == o->end() ? none : it->second;
    }
    std::string str(const std::string& fallback = "") const { return kind == String ? s : fallback; }
    double num(double fallback = 0) const { return kind == Number ? n : fallback; }
    bool boolean(bool fallback = false) const { return kind == Bool ? b : fallback; }
    const Array& items() const {
        static const Array none;
        return kind == ArrayKind ? *a : none;
    }
};

inline void encodeUTF8(std::string& out, uint32_t cp) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}

struct Parser {
    const std::string& in;
    size_t at = 0;
    bool ok = true;
    explicit Parser(const std::string& text) : in(text) {}

    void ws() { while (at < in.size() && (in[at] == ' ' || in[at] == '\n' || in[at] == '\r' || in[at] == '\t')) at++; }
    bool take(char c) { ws(); if (at < in.size() && in[at] == c) { at++; return true; } return false; }

    Value parse() {
        ws();
        if (at >= in.size()) { ok = false; return Value(); }
        char c = in[at];
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"') return Value(string());
        if (c == 't' && in.compare(at, 4, "true") == 0) { at += 4; return Value(true); }
        if (c == 'f' && in.compare(at, 5, "false") == 0) { at += 5; return Value(false); }
        if (c == 'n' && in.compare(at, 4, "null") == 0) { at += 4; return Value(); }
        return number();
    }

    Value number() {
        size_t start = at;
        while (at < in.size() && (isdigit((unsigned char)in[at]) || in[at] == '-' || in[at] == '+' || in[at] == '.' || in[at] == 'e' || in[at] == 'E')) at++;
        if (start == at) { ok = false; return Value(); }
        return Value(strtod(in.substr(start, at - start).c_str(), nullptr));
    }

    std::string string() {
        std::string out;
        if (!take('"')) { ok = false; return out; }
        while (at < in.size()) {
            char c = in[at++];
            if (c == '"') return out;
            if (c != '\\') { out += c; continue; }
            if (at >= in.size()) break;
            char e = in[at++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    if (at + 4 > in.size()) { ok = false; return out; }
                    uint32_t cp = (uint32_t)strtoul(in.substr(at, 4).c_str(), nullptr, 16);
                    at += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && at + 6 <= in.size() && in[at] == '\\' && in[at + 1] == 'u') {
                        uint32_t lo = (uint32_t)strtoul(in.substr(at + 2, 4).c_str(), nullptr, 16);
                        if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); at += 6; }
                    }
                    encodeUTF8(out, cp);
                    break;
                }
                default: out += e;
            }
        }
        ok = false;
        return out;
    }

    Value array() {
        Array items;
        take('[');
        if (take(']')) return Value(items);
        while (ok) {
            items.push_back(parse());
            if (take(']')) break;
            if (!take(',')) { ok = false; break; }
        }
        return Value(items);
    }

    Value object() {
        Object fields;
        take('{');
        if (take('}')) return Value(fields);
        while (ok) {
            ws();
            std::string key = string();
            if (!ok || !take(':')) { ok = false; break; }
            fields[key] = parse();
            if (take('}')) break;
            if (!take(',')) { ok = false; break; }
        }
        return Value(fields);
    }
};

inline bool parse(const std::string& text, Value& out) {
    Parser p(text);
    out = p.parse();
    return p.ok;
}

inline void quote(std::string& out, const std::string& s) {
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) { char buf[8]; snprintf(buf, sizeof buf, "\\u%04x", c); out += buf; }
                else out += (char)c;
        }
    }
    out += '"';
}

inline void serialize(const Value& v, std::string& out) {
    switch (v.kind) {
        case Value::Null: out += "null"; break;
        case Value::Bool: out += v.b ? "true" : "false"; break;
        case Value::Number: {
            char buf[64];
            if (v.n == (double)(long long)v.n) snprintf(buf, sizeof buf, "%lld", (long long)v.n);
            else snprintf(buf, sizeof buf, "%.6g", v.n);
            out += buf;
            break;
        }
        case Value::String: quote(out, v.s); break;
        case Value::ArrayKind: {
            out += '[';
            bool first = true;
            for (const auto& item : *v.a) { if (!first) out += ','; first = false; serialize(item, out); }
            out += ']';
            break;
        }
        case Value::ObjectKind: {
            out += '{';
            bool first = true;
            for (const auto& [k, item] : *v.o) { if (!first) out += ','; first = false; quote(out, k); out += ':'; serialize(item, out); }
            out += '}';
            break;
        }
    }
}

inline std::string serialize(const Value& v) {
    std::string out;
    serialize(v, out);
    return out;
}

}  // namespace json
