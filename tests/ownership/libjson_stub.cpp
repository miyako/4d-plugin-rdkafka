// Synthetic stand-in for the vendored libjson.a (built against the legacy GNU
// libstdc++ ABI, which current macOS toolchains cannot link). Only the C API
// imported by 4DPlugin.cpp is modelled; every node and every written string
// is tracked so leaks and double frees are reported. Output is compact JSON
// (json_write_formatted adds no whitespace in this model).
#include "libjson.h"

#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <set>
#include <string>
#include <vector>

int g_json_nodes_live = 0;
int g_json_strings_live = 0;

namespace {

struct Node {
    char type;
    std::wstring name;
    std::wstring str;
    long num;
    bool boolean;
    std::vector<Node *> children;
    bool owned_by_parent;
};

std::set<Node *> &nodes() { static std::set<Node *> s; return s; }
std::set<void *> &strings() { static std::set<void *> s; return s; }

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "LIBJSON STUB VIOLATION: %s\n", msg);
    fflush(stderr);
    abort();
}

Node *check(JSONNODE *n) {
    Node *p = (Node *)n;
    if(!nodes().count(p)) die("unknown or freed node");
    return p;
}

Node *make(char type, const json_char *name) {
    Node *n = new Node();
    n->type = type;
    if(name) n->name = name;
    n->num = 0;
    n->boolean = false;
    n->owned_by_parent = false;
    nodes().insert(n);
    g_json_nodes_live++;
    return n;
}

void destroy(Node *n) {
    for(Node *c : n->children) destroy(c);
    nodes().erase(n);
    g_json_nodes_live--;
    delete n;
}

void quote(std::wstring &out, const std::wstring &s) {
    out += L'"';
    for(wchar_t c : s) {
        if(c == L'"' || c == L'\\') { out += L'\\'; out += c; }
        else if(c == L'\n') out += L"\\n";
        else out += c;
    }
    out += L'"';
}

void write(std::wstring &out, const Node *n, bool named) {
    if(named) { quote(out, n->name); out += L':'; }
    switch(n->type) {
        case JSON_NULL: out += L"null"; break;
        case JSON_STRING: quote(out, n->str); break;
        case JSON_NUMBER: out += std::to_wstring(n->num); break;
        case JSON_BOOL: out += n->boolean ? L"true" : L"false"; break;
        case JSON_ARRAY:
        case JSON_NODE: {
            out += n->type == JSON_ARRAY ? L'[' : L'{';
            for(size_t i = 0; i < n->children.size(); ++i) {
                if(i) out += L',';
                write(out, n->children[i], n->type == JSON_NODE);
            }
            out += n->type == JSON_ARRAY ? L']' : L'}';
            break;
        }
        default: die("unknown node type");
    }
}

json_char *emit(json_const JSONNODE *node) {
    std::wstring out;
    write(out, check((JSONNODE *)node), false);
    json_char *s = (json_char *)malloc((out.size() + 1) * sizeof(json_char));
    wmemcpy(s, out.c_str(), out.size() + 1);
    strings().insert(s);
    g_json_strings_live++;
    return s;
}

} // namespace

extern "C" {

void json_free(void *str) {
    if(!str) return;
    if(!strings().erase(str)) die("json_free of a string not returned by json_write");
    g_json_strings_live--;
    free(str);
}

void json_delete(JSONNODE *node) {
    Node *n = check(node);
    if(n->owned_by_parent) die("json_delete of a node owned by its parent");
    destroy(n);
}

JSONNODE *json_new(char type) {
    if(type != JSON_NODE && type != JSON_ARRAY) die("unmodelled json_new type");
    return (JSONNODE *)make(type, nullptr);
}

JSONNODE *json_new_a(json_const json_char *name, json_const json_char *value) {
    Node *n = make(JSON_STRING, name);
    n->str = value ? value : L"";
    return (JSONNODE *)n;
}

JSONNODE *json_new_i(json_const json_char *name, json_int_t value) {
    Node *n = make(JSON_NUMBER, name);
    n->num = (long)value;
    return (JSONNODE *)n;
}

void json_set_a(JSONNODE *node, json_const json_char *value) {
    Node *n = check(node);
    n->type = JSON_STRING;
    n->str = value ? value : L"";
}

void json_set_b(JSONNODE *node, json_bool_t value) {
    Node *n = check(node);
    n->type = JSON_BOOL;
    n->boolean = value != 0;
}

void json_set_name(JSONNODE *node, json_const json_char *name) {
    check(node)->name = name ? name : L"";
}

void json_nullify(JSONNODE *node) {
    Node *n = check(node);
    if(n->type == JSON_NODE || n->type == JSON_ARRAY) die("unmodelled nullify of a container");
    n->type = JSON_NULL;
}

JSONNODE *json_get(JSONNODE *node, json_const json_char *name) {
    Node *n = check(node);
    for(Node *c : n->children)
        if(c->name == name) return (JSONNODE *)c;
    return nullptr;
}

void json_push_back(JSONNODE *node, JSONNODE *node2) {
    Node *n = check(node);
    Node *c = check(node2);
    if(n->type != JSON_NODE && n->type != JSON_ARRAY) die("push_back into a leaf");
    if(c->owned_by_parent) die("node pushed into two parents");
    c->owned_by_parent = true;
    n->children.push_back(c);
}

json_char *json_write(json_const JSONNODE *node) { return emit(node); }
json_char *json_write_formatted(json_const JSONNODE *node) { return emit(node); }

} // extern "C"
