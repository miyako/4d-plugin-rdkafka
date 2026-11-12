/*
 * Synthetic 4D engine boundary for RDKAFKA ownership regressions.
 *
 * Links the real plugin source (rdkafka/4DPlugin.cpp), the plugin classes
 * (4D Plugin API/Classes), the bundled, unmodified 4D Plugin API
 * (4DPluginAPI.c) and the vendored a/libjson.a. librdkafka is replaced by
 * rdkafka_stub.cpp so no broker is ever contacted. On the 4D side only
 * gCall4D is replaced: it models engine-side allocations (Unistrings,
 * handles, pictures) with malloc/free so ASan reports double frees and
 * use-after-free, and keeps a live set of every engine string, handle and
 * picture so leaks are detected exactly.
 *
 * Engine semantics modelled (SDK contract):
 *  - PA_CreateVariable(eVK_Picture) allocates an empty engine picture
 *    (4DPluginAPI.c); PA_SetStringVariable and PA_SetPictureVariable
 *    overwrite the variable shallowly.
 *  - PA_ClearVariable releases what the variable owns.
 *  - Pictures are reference counted: PA_DuplicatePicture(p, 1) retains,
 *    PA_DisposePicture releases one reference.
 *  - Commands that write a picture into an output parameter (READ PICTURE
 *    FILE, CREATE THUMBNAIL) release the picture previously held by that
 *    variable (the most forgiving engine model).
 *  - PA_ConvertCharsetToCharset returns the BYTE size written (SDK comment).
 *    UTF-32 <-> UTF-16 is modelled for the BMP only (inputs are ASCII).
 *
 * No files, sockets or brokers are touched.
 */

#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

extern int g_rk_live, g_conf_live, g_topic_conf_live, g_topic_live;
extern int g_msg_live, g_metadata_live, g_grplist_live;
extern std::string g_brokers;
extern int g_json_nodes_live, g_json_strings_live;

extern "C" Call4DProcPtr gCall4D;

namespace {

typedef std::basic_string<PA_Unichar> u16;

struct Handle { char *data; PA_long32 len; };
struct Pic { int refs; };

std::set<void *> g_strings;
std::set<Handle *> g_handles;
std::set<Pic *> g_pics;

u16 g_read_path, g_convert_type;
int g_process_info = 0;
int g_transform_op = 0, g_thumb_w = 0, g_thumb_h = 0;

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "ENGINE VIOLATION: %s\n", msg);
    fflush(stderr);
    abort();
}

PA_Unistring new_string(const PA_Unichar *src, size_t len) {
    PA_Unichar *buf = (PA_Unichar *)malloc((len + 1) * sizeof(PA_Unichar));
    if(len) memcpy(buf, src, len * sizeof(PA_Unichar));
    buf[len] = 0;
    g_strings.insert(buf);
    PA_Unistring s;
    s.fLength = (PA_long32)len;
    s.fString = buf;
    s.fReserved1 = 0;
    s.fReserved2 = 0;
    return s;
}

void free_string(PA_Unistring *s) {
    if(!s->fString) return;
    if(!g_strings.erase(s->fString)) die("disposed a string the engine does not own");
    free(s->fString);
    s->fString = 0;
    s->fLength = 0;
}

Handle *new_handle(PA_long32 len) {
    Handle *h = (Handle *)malloc(sizeof(Handle));
    h->data = (char *)calloc(1, len ? len : 1);
    h->len = len;
    g_handles.insert(h);
    return h;
}

Handle *checked(PA_Handle ph) {
    Handle *h = (Handle *)ph;
    if(!g_handles.count(h)) die("used an unknown handle");
    return h;
}

void free_handle(Handle *h) {
    if(!h) return;
    checked((PA_Handle)h);
    g_handles.erase(h);
    free(h->data);
    free(h);
}

Pic *new_pic() {
    Pic *p = (Pic *)malloc(sizeof(Pic));
    p->refs = 1;
    g_pics.insert(p);
    return p;
}

Pic *live_pic(PA_Picture pp) {
    Pic *p = (Pic *)pp;
    if(!g_pics.count(p)) die("used a picture the engine does not own");
    return p;
}

void release_pic(PA_Picture pp) {
    if(!pp) return;
    Pic *p = live_pic(pp);
    if(--p->refs == 0) { g_pics.erase(p); free(p); }
}

void clear_var(PA_Variable *v) {
    switch(v->fType) {
        case eVK_Unistring: free_string(&v->uValue.fString); break;
        case eVK_Picture: release_pic(v->uValue.fPicture); v->uValue.fPicture = 0; break;
        case eVK_ArrayUnicode: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Unistring *items = (PA_Unistring *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) free_string(&items[i]);
                free_handle(h);
            }
            break;
        }
        default: break;
    }
    v->fType = eVK_Undefined;
}

u16 live_text(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Unistring) die(what);
    if(!g_strings.count(v.uValue.fString.fString)) die("engine received a string it does not own");
    return u16(v.uValue.fString.fString, v.uValue.fString.fLength);
}

void live_picture_var(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Picture || !v.uValue.fPicture) die(what);
    live_pic(v.uValue.fPicture);
}

PA_long32 longint(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Longint) die(what);
    return v.uValue.fLongint;
}

double real(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Real) die(what);
    return v.uValue.fReal;
}

/* output picture parameter: the engine releases the old value and stores a new picture */
void write_picture(PA_Variable *v) {
    if(v->fType == eVK_Picture) release_pic(v->uValue.fPicture);
    else if(v->fType != eVK_Undefined) die("picture output parameter has a non-picture value");
    v->fType = eVK_Picture;
    v->uValue.fPicture = new_pic();
}

void command(EngineBlock *eb) {
    PA_Variable **v = (PA_Variable **)eb->fPtr1;
    PA_long32 n = (PA_long32)eb->fParam2;
    switch(eb->fParam1) {
        case 678: /* READ PICTURE FILE(path; picture) */
            if(n != 2) die("READ PICTURE FILE parameter count");
            g_read_path = live_text(*v[0], "path parameter is not text");
            write_picture(v[1]);
            break;
        case 1002: /* CONVERT PICTURE(picture; type) */
            if(n != 2) die("CONVERT PICTURE parameter count");
            live_picture_var(*v[0], "CONVERT PICTURE picture");
            g_convert_type = live_text(*v[1], "type parameter is not text");
            break;
        case 988: /* TRANSFORM PICTURE(picture; operator) */
            if(n != 2) die("TRANSFORM PICTURE parameter count");
            live_picture_var(*v[0], "TRANSFORM PICTURE picture");
            g_transform_op = longint(*v[1], "operator is not longint");
            break;
        case 457: /* PICTURE PROPERTIES(picture; width; height) */
            if(n != 3) die("PICTURE PROPERTIES parameter count");
            live_picture_var(*v[0], "PICTURE PROPERTIES picture");
            v[1]->fType = eVK_Longint; v[1]->uValue.fLongint = 640;
            v[2]->fType = eVK_Longint; v[2]->uValue.fLongint = 480;
            break;
        case 679: /* CREATE THUMBNAIL(picture; thumbnail; width; height) */
            if(n != 4) die("CREATE THUMBNAIL parameter count");
            live_picture_var(*v[0], "CREATE THUMBNAIL source");
            g_thumb_w = longint(*v[2], "width is not longint");
            g_thumb_h = longint(*v[3], "height is not longint");
            write_picture(v[1]);
            break;
        default: die("unexpected command");
    }
    eb->fError = 0;
}

void engine(short selector, EngineBlock *eb) {
    switch(selector) {
        case EX_HANDLE_MANAGER:
            switch(eb->fParam1) {
                case 1: eb->fHandle = (PA_Handle)new_handle((PA_long32)eb->fParam2); eb->fError = 0; return;
                case 2: free_handle((Handle *)eb->fHandle); eb->fError = 0; return;
                case 3: {
                    Handle *h = checked(eb->fHandle);
                    PA_long32 n = (PA_long32)eb->fParam2;
                    h->data = (char *)realloc(h->data, n ? n : 1);
                    if(n > h->len) memset(h->data + h->len, 0, n - h->len);
                    h->len = n; eb->fError = 0; return;
                }
                case 4: eb->fParam2 = checked(eb->fHandle)->len; eb->fError = 0; return;
                case 5: eb->fParam3 = (sLONG_PTR)checked(eb->fHandle)->data; eb->fError = 0; return;
                case 6: checked(eb->fHandle); eb->fError = 0; return;
                default: die("unmodelled handle manager call");
            }
        case EX_CREATE_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_SET_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            free_string(&eb->fUniString1);
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_DISPOSE_UNISTRING: free_string(&eb->fUniString1); return;
        case EX_CLEAR_VARIABLE: clear_var((PA_Variable *)eb->fPtr1); return;
        case EX_YIELD_ABSOLUTE: return;
        case EX_CREATE_PICTURE: eb->fPicture = new_pic(); eb->fError = 0; return;
        case EX_DISPOSE_PICTURE: release_pic(eb->fPicture); return;
        case EX_DUPLICATE_PICTURE:
            if(eb->fParam1 == 0) live_pic(eb->fPicture)->refs++;
            else { live_pic(eb->fPicture); eb->fPicture = new_pic(); }
            return;
        case EX_GET_PICTURE_DATA:
            live_pic(eb->fPicture);
            memset(&eb->fUniString1, 0, sizeof eb->fUniString1);
            eb->fError = -1; /* no stored formats */
            return;
        case EX_CONVERT_CHARSET_TO_CHARSET: {
            const char *from = (const char *)eb->fPtr1;
            PA_long32 fromSize = (PA_long32)eb->fParam1, toSize = (PA_long32)eb->fParam3, out = 0;
            if(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16) {
                PA_Unichar *to = (PA_Unichar *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize && (out + 1) * (PA_long32)sizeof(PA_Unichar) <= toSize; ++i)
                    to[out++] = (unsigned char)from[i];
                eb->fParam3 = out * (PA_long32)sizeof(PA_Unichar); /* byte size */
            } else if(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_8) {
                const PA_Unichar *f = (const PA_Unichar *)from;
                char *to = (char *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 2 && out < toSize; ++i) to[out++] = (char)f[i];
                eb->fParam3 = out;
            } else if(eb->fParam2 == eVTC_UTF_32 && eb->fParam4 == eVTC_UTF_16) {
                const uint32_t *f = (const uint32_t *)from;
                PA_Unichar *to = (PA_Unichar *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 4 && (out + 1) * (PA_long32)sizeof(PA_Unichar) <= toSize; ++i) {
                    if(f[i] > 0xFFFF) die("non-BMP input");
                    to[out++] = (PA_Unichar)f[i];
                }
                eb->fParam3 = out * (PA_long32)sizeof(PA_Unichar); /* byte size */
            } else if(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_32) {
                const PA_Unichar *f = (const PA_Unichar *)from;
                uint32_t *to = (uint32_t *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 2 && (out + 1) * 4 <= toSize; ++i) to[out++] = f[i];
                eb->fParam3 = out * 4; /* byte size */
            } else die("unmodelled charset conversion");
            eb->fError = 0;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: command(eb); return;
        case EX_CURRENT_PROCESS_NUMBER: eb->fParam1 = 5; return;
        case EX_GET_PROCESS_INFO:
            if(eb->fParam1 != 5) die("process info for another process");
            memset(eb->fUString, 0, sizeof eb->fUString);
            eb->fUString[0] = '$'; eb->fUString[1] = 'x'; eb->fUString[2] = 'x';
            eb->fParam2 = 0; eb->fParam3 = 0; eb->fError = 0;
            g_process_info++;
            return;
        default: {
            char msg[64];
            snprintf(msg, sizeof msg, "unmodelled selector %d", (int)selector);
            die(msg);
        }
    }
}

void expect(bool ok, const char *what) {
    if(!ok) {
        fprintf(stderr, "FAIL: %s (live engine strings: %zu, pictures: %zu)\n", what, g_strings.size(), g_pics.size());
        for(void *p : g_strings) {
            fprintf(stderr, "  live string: \"");
            for(PA_Unichar *c = (PA_Unichar *)p; *c && c - (PA_Unichar *)p < 40; ++c) fputc(*c < 128 ? (int)*c : '?', stderr);
            fprintf(stderr, "\"\n");
        }
        exit(1);
    }
}

void expect_nothing_live(const char *what) {
    expect(g_strings.empty(), what);
    expect(g_pics.empty(), what);
}

u16 to_u16(const char *s) { u16 r; for(; *s; ++s) r.push_back((PA_Unichar)(unsigned char)*s); return r; }

/* ---- KAFKA commands through PluginMain (synthetic librdkafka) ---- */

PA_Variable text_array(const std::vector<u16> &items) {
    /* built directly: PA_CreateVariable(eVK_ArrayUnicode) would allocate its own handle and element 0 */
    PA_Variable v;
    memset(&v, 0, sizeof v);
    v.fType = eVK_ArrayUnicode;
    Handle *h = new_handle((PA_long32)((items.size() + 1) * sizeof(PA_Unistring)));
    PA_Unistring *a = (PA_Unistring *)h->data;
    a[0] = new_string(0, 0);
    for(size_t i = 0; i < items.size(); ++i) a[i + 1] = new_string(items[i].c_str(), items[i].size());
    v.uValue.fArray.fCurrent = 0;
    v.uValue.fArray.fNbElements = (PA_long32)items.size();
    v.uValue.fArray.fData = (PA_Handle)h;
    return v;
}

PA_Variable brokers() { return text_array({ to_u16("b1.invalid:9092"), to_u16("b2.invalid:9092") }); }

bool contains(const u16 &s, const char *needle) { return s.find(to_u16(needle)) != u16::npos; }

void expect_rdkafka_balanced(int leaked_json_nodes = 0) {
    expect(g_rk_live == 0 && g_conf_live == 0 && g_topic_conf_live == 0 && g_topic_live == 0, "rdkafka handles released");
    expect(g_msg_live == 0 && g_metadata_live == 0 && g_grplist_live == 0, "rdkafka messages and lists released");
    expect(g_json_nodes_live == leaked_json_nodes && g_json_strings_live == 0, "libjson nodes and strings released");
}

void expect_engine_balanced(const char *what) {
    expect_nothing_live(what);
    expect(g_handles.empty(), what);
}

void control_kafka_get_version() {
    {
        PA_Unistring r = new_string(0, 0);
        sLONG_PTR ret = (sLONG_PTR)&r;
        PluginBlock pb = { 0, &ret, 0 };
        PluginMain(3, &pb); /* KAFKA Get version */
        expect(u16(r.fString, r.fLength) == to_u16("0.11.1-stub"), "version returned");
        free_string(&r);
    }
    expect_engine_balanced("KAFKA Get version leaves nothing behind");
}

void consume(PA_long32 count, u16 *json, int *code) {
    PA_Variable b = brokers();
    PA_Unistring topic = new_string(to_u16("t").c_str(), 1);
    PA_Unistring out = new_string(to_u16("stale").c_str(), 5);
    PA_Unistring group = new_string(0, 0);
    PA_long32 partition = 0, offset = 0;
    sLONG_PTR ret = -1;
    void *params[7] = { &b, &topic, &out, &partition, &group, &offset, &count };
    PluginBlock pb = { params, &ret, 0 };
    PluginMain(1, &pb); /* KAFKA Consume */
    *json = u16(out.fString, out.fLength);
    *code = (int)(PA_long32)ret;
    expect(g_brokers == "b1.invalid:9092,b2.invalid:9092", "brokers joined from the borrowed array");
    PA_ClearVariable(&b);
    free_string(&topic);
    free_string(&out);
    free_string(&group);
}

void check_consumed(const u16 &json, int code) {
    expect(code == 0, "KAFKA Consume returned 0");
    expect(json.size() > 2 && json[0] == '[', "JSON array returned");
    expect(contains(json, "\"value\":\"hello\"") && contains(json, "\"key\":\"k\"") && contains(json, "\"offset\":7"), "message fields returned");
    expect(contains(json, "\"data\":\"aGVsbG8=\"") && contains(json, "\"create_time\":\"1234\"") && contains(json, "\"topic\":\"t\""), "payload/timestamp/topic returned");
}

void control_kafka_consume() {
    u16 json; int code;
    consume(1, &json, &code);
    check_consumed(json, code);
    expect_rdkafka_balanced();
    expect_engine_balanced("KAFKA Consume leaves nothing behind");
}

void control_kafka_consume_until_eof() {
    u16 json; int code;
    consume(0, &json, &code);
    check_consumed(json, code);
    expect_rdkafka_balanced();
    expect_engine_balanced("KAFKA Consume leaves nothing behind");
}

void control_kafka_produce() {
    {
        PA_Variable b = brokers();
        PA_Unistring topic = new_string(to_u16("t").c_str(), 1);
        Handle *blob = new_handle(5);
        memcpy(blob->data, "hello", 5);
        PA_Handle payload = (PA_Handle)blob;
        PA_Unistring key = new_string(to_u16("k").c_str(), 1);
        PA_Unistring out = new_string(to_u16("stale").c_str(), 5);
        PA_long32 partition = 0;
        sLONG_PTR ret = -1;
        void *params[6] = { &b, &topic, &payload, &key, &out, &partition };
        PluginBlock pb = { params, &ret, 0 };
        PluginMain(2, &pb); /* KAFKA Produce */
        u16 json(out.fString, out.fLength);
        expect((PA_long32)ret == 0, "KAFKA Produce returned 0");
        expect(contains(json, "\"value\":\"hello\"") && contains(json, "\"key\":\"k\"") && contains(json, "\"offset\":42"), "delivery report returned");
        expect(contains(json, "\"data\":\"aGVsbG8=\""), "payload copied from the borrowed BLOB");
        expect(payload == (PA_Handle)blob && g_handles.count(blob), "input BLOB untouched");
        PA_ClearVariable(&b);
        free_string(&topic);
        free_handle(blob);
        free_string(&key);
        free_string(&out);
    }
    expect_rdkafka_balanced();
    expect_engine_balanced("KAFKA Produce leaves nothing behind");
}

void control_kafka_get_topics() {
    {
        PA_Variable b = brokers();
        PA_Unistring topic = new_string(to_u16("t").c_str(), 1);
        PA_Unistring out = new_string(to_u16("stale").c_str(), 5);
        sLONG_PTR ret = -1;
        void *params[3] = { &b, &topic, &out };
        PluginBlock pb = { params, &ret, 0 };
        PluginMain(4, &pb); /* KAFKA Get topics */
        u16 json(out.fString, out.fLength);
        expect((PA_long32)ret == 0, "KAFKA Get topics returned 0");
        expect(contains(json, "\"host\":\"broker.invalid\"") && contains(json, "\"partitions\":[{\"id\":0,\"leader\":1}]"), "metadata returned");
        PA_ClearVariable(&b);
        free_string(&topic);
        free_string(&out);
    }
    expect_rdkafka_balanced();
    expect_engine_balanced("KAFKA Get topics leaves nothing behind");
}

void control_kafka_get_groups() {
    {
        PA_Variable b = brokers();
        PA_Unistring out = new_string(to_u16("stale").c_str(), 5);
        sLONG_PTR ret = -1;
        void *params[2] = { &b, &out };
        PluginBlock pb = { params, &ret, 0 };
        PluginMain(5, &pb); /* KAFKA Get groups */
        u16 json(out.fString, out.fLength);
        expect((PA_long32)ret == 0, "KAFKA Get groups returned 0");
        expect(contains(json, "\"group\":\"g\"") && contains(json, "\"member_id\":\"m\""), "groups returned");
        PA_ClearVariable(&b);
        free_string(&out);
    }
    /* json_group_list() creates an unused json_item_groups array and never
       deletes it: a pre-existing libjson leak (not 4D ownership), pinned so
       any other imbalance still fails. */
    expect_rdkafka_balanced(1);
    expect_engine_balanced("KAFKA Get groups leaves nothing behind");
}

/* kCloseProcess on the $xx exit process: PA_GetProcessInfo fills a C_TEXT */
void control_close_process() {
    PluginBlock pb = { 0, 0, 0 };
    PluginMain(kCloseProcess, &pb);
    expect(g_process_info == 1, "process info queried");
    expect_engine_balanced("kCloseProcess leaves nothing behind");
}

/* Contract 1/2: ARRAY_TEXT fills the array via PA_SetStringInArray and must not dispose. */
void control_array_text_transfer() {
    {
        ARRAY_TEXT a;
        a.appendUTF16String((const PA_Unichar *)u"", 0);
        a.appendUTF16String((const PA_Unichar *)u"x", 1);
        a.appendUTF16String((const PA_Unichar *)u"yz", 2);
        PA_Variable arr = PA_CreateVariable(eVK_ArrayUnicode);
        void *params[1] = { &arr };
        a.toParamAtIndex((PackagePtr)params, 1);
        expect(arr.uValue.fArray.fNbElements == 2, "two elements");
        expect(g_strings.size() == 3, "array owns three strings");
        ARRAY_TEXT b;
        b.fromParamAtIndex((PackagePtr)params, 1);
        CUTF16String s; b.copyUTF16StringAtIndex(&s, 2);
        expect(s == CUTF16String((const PA_Unichar *)u"yz"), "borrowed read");
        PA_ClearVariable(&arr);
    }
    expect_nothing_live("array strings released with the array");
}

/* ---- C_PICTURE (built, unreachable from every KAFKA command) ---- */

/* a picture held by C_PICTURE; the harness drops its own reference */
void with_picture(const std::function<void(C_PICTURE &)> &f) {
    {
        C_PICTURE pic;
        PA_Picture src = PA_CreatePicture(0, 0);
        pic.setPicture(src);
        PA_DisposePicture(src);
        expect(g_pics.size() == 1, "one picture held");
        f(pic);
    }
}

void defect_picture_fromfile_ownership() {
    {
        C_PICTURE pic;
        CUTF8String path((const uint8_t *)"/rdkafka-synthetic/does-not-exist.png");
        pic.fromFileAtPath(&path);
        expect(g_read_path == to_u16("/rdkafka-synthetic/does-not-exist.png"), "path delivered");
        expect(g_pics.size() == 1, "only the loaded picture is live");
    }
    expect_nothing_live("READ PICTURE FILE parameters and result released");
}

void defect_picture_setbytes_leak() {
    {
        C_PICTURE pic;
        const uint8_t bytes[] = { 1, 2, 3 };
        pic.setBytes(bytes, sizeof bytes);
        expect(g_pics.size() == 1, "only the held picture is live");
    }
    expect_nothing_live("picture created by setBytes released");
}

void defect_picture_createcopy_ownership() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createCopyPNG();
        expect(g_convert_type == to_u16(".png"), "type delivered");
        expect(p == pic.getPicture(), "retained copy returned");
        PA_DisposePicture(p);
    });
    expect_nothing_live("CONVERT PICTURE parameters released");
}

void defect_picture_grayscale_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createGrayScale();
        expect(g_transform_op == 101, "operator delivered");
        PA_DisposePicture(p);
    });
    expect_nothing_live("TRANSFORM PICTURE parameters released");
}

void defect_picture_getsize_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        unsigned int w = 0, h = 0;
        pic.getSize(&w, &h);
        expect(w == 640 && h == 480, "size delivered");
    });
    expect_nothing_live("PICTURE PROPERTIES parameters released");
}

void defect_picture_thumbnail_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture t = pic.createThumbnail(32, 24);
        expect(g_thumb_w == 32 && g_thumb_h == 24, "size delivered");
        expect(t && t != pic.getPicture() && g_pics.count((Pic *)t), "thumbnail handed to the caller");
        PA_DisposePicture(t);
    });
    expect_nothing_live("CREATE THUMBNAIL parameters released");
}

/* Contract 6 control: C_PICTURE parameter/return transfer. */
void control_picture_param_return() {
    PA_Picture in = PA_CreatePicture(0, 0);
    PA_Picture out = PA_CreatePicture(0, 0);
    PA_Picture ret = 0;
    {
        C_PICTURE pic;
        void *params[2] = { &in, &out };
        pic.fromParamAtIndex((PackagePtr)params, 1);
        pic.toParamAtIndex((PackagePtr)params, 2);
        pic.setReturn((sLONG_PTR *)&ret);
        expect(out == in && ret == in, "same picture retained");
    }
    PA_DisposePicture(in);
    PA_DisposePicture(out);
    PA_DisposePicture(ret);
    expect_nothing_live("all references balanced");
}

const std::map<std::string, std::function<void()>> kTests = {
    { "control_kafka_get_version", control_kafka_get_version },
    { "control_kafka_consume", control_kafka_consume },
    { "control_kafka_consume_until_eof", control_kafka_consume_until_eof },
    { "control_kafka_produce", control_kafka_produce },
    { "control_kafka_get_topics", control_kafka_get_topics },
    { "control_kafka_get_groups", control_kafka_get_groups },
    { "control_close_process", control_close_process },
    { "control_array_text_transfer", control_array_text_transfer },
    { "defect_picture_fromfile_ownership", defect_picture_fromfile_ownership },
    { "defect_picture_setbytes_leak", defect_picture_setbytes_leak },
    { "defect_picture_createcopy_ownership", defect_picture_createcopy_ownership },
    { "defect_picture_grayscale_owner_leak", defect_picture_grayscale_owner_leak },
    { "defect_picture_getsize_owner_leak", defect_picture_getsize_owner_leak },
    { "defect_picture_thumbnail_owner_leak", defect_picture_thumbnail_owner_leak },
    { "control_picture_param_return", control_picture_param_return },
};

} // namespace

int main(int argc, char **argv) {
    gCall4D = engine;
    if(argc == 2 && std::string(argv[1]) == "--list") {
        for(auto &t : kTests) printf("%s\n", t.first.c_str());
        return 0;
    }
    if(argc != 2 || !kTests.count(argv[1])) { fprintf(stderr, "usage: %s --list | <test>\n", argv[0]); return 2; }
    kTests.at(argv[1])();
    printf("PASS %s\n", argv[1]);
    return 0;
}
