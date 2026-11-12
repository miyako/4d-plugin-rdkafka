/*
 * Synthetic librdkafka boundary for the ownership harness.
 *
 * Replaces the vendored a/librdkafka.a so no socket is ever opened and no
 * broker is contacted. Only the calls the KAFKA commands make on the paths
 * the controls drive are modelled; any other call aborts.
 *
 * Modelled behaviour:
 *  - rd_kafka_new() takes ownership of the conf on success.
 *  - Static consumer: rd_kafka_consume() returns one message ("hello",
 *    key "k", offset 7, create time 1234), then PARTITION_EOF.
 *  - Producer: rd_kafka_produce(RD_KAFKA_MSG_F_COPY) queues a copy; poll/
 *    flush deliver it to the dr_msg_cb with _private = msg_opaque.
 *  - Metadata and group lists are synthetic heap structures released by
 *    their destroy calls.
 *  - Keys carry a trailing NUL: 4DPlugin.cpp passes rkmessage->key to
 *    strlen (json_set_s); real librdkafka keys are not NUL-terminated.
 *  - rd_kafka_message_destroy() defers the free to rd_kafka_destroy():
 *    4DPlugin.cpp reads rkmessage->err after destroying the message.
 *  Both are pre-existing librdkafka-side issues outside the 4D ownership
 *  contracts this harness checks; see README.md.
 */

#include "rdkafka.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct rd_kafka_conf_s {
    void *opaque;
    void (*error_cb)(rd_kafka_t *, int, const char *, void *);
    void (*dr_msg_cb)(rd_kafka_t *, const rd_kafka_message_t *, void *);
};
struct rd_kafka_topic_conf_s { int unused; };
struct rd_kafka_s {
    rd_kafka_type_t type;
    rd_kafka_conf_t *conf;
    std::vector<rd_kafka_message_t *> queued;
};
struct rd_kafka_topic_s { rd_kafka_t *rk; std::string name; int next; };

int g_rk_live = 0, g_conf_live = 0, g_topic_conf_live = 0, g_topic_live = 0;
int g_msg_live = 0, g_metadata_live = 0, g_grplist_live = 0;
std::string g_brokers;
std::vector<rd_kafka_message_t *> g_destroyed;

[[noreturn]] static void die(const char *what) {
    fprintf(stderr, "RDKAFKA STUB VIOLATION: %s\n", what);
    fflush(stderr);
    abort();
}

static char *dup_bytes(const void *p, size_t n) {
    char *r = (char *)malloc(n + 1);
    if(n) memcpy(r, p, n);
    r[n] = 0;
    return r;
}

static rd_kafka_message_t *new_message(rd_kafka_topic_t *rkt, rd_kafka_resp_err_t err, int64_t offset,
                                       const void *payload, size_t len, const void *key, size_t key_len) {
    rd_kafka_message_t *m = (rd_kafka_message_t *)calloc(1, sizeof *m);
    m->err = err;
    m->rkt = rkt;
    m->partition = 0;
    m->offset = offset;
    m->payload = payload ? dup_bytes(payload, len) : 0;
    m->len = len;
    m->key = key ? dup_bytes(key, key_len) : 0;
    m->key_len = key_len;
    g_msg_live++;
    return m;
}

static void free_message(rd_kafka_message_t *m) {
    free(m->payload);
    free(m->key);
    free(m);
    g_msg_live--;
}

extern "C" {

rd_kafka_conf_t *rd_kafka_conf_new(void) {
    g_conf_live++;
    return (rd_kafka_conf_t *)calloc(1, sizeof(rd_kafka_conf_t));
}
void rd_kafka_conf_destroy(rd_kafka_conf_t *conf) { if(conf) { g_conf_live--; free(conf); } }
void rd_kafka_conf_set_opaque(rd_kafka_conf_t *conf, void *opaque) { conf->opaque = opaque; }
void rd_kafka_conf_set_error_cb(rd_kafka_conf_t *conf, void (*cb)(rd_kafka_t *, int, const char *, void *)) { conf->error_cb = cb; }
void rd_kafka_conf_set_dr_msg_cb(rd_kafka_conf_t *conf, void (*cb)(rd_kafka_t *, const rd_kafka_message_t *, void *)) { conf->dr_msg_cb = cb; }
rd_kafka_conf_res_t rd_kafka_conf_set(rd_kafka_conf_t *, const char *name, const char *value, char *, size_t) {
    if(!strcmp(name, "bootstrap.servers")) { g_brokers = value; return RD_KAFKA_CONF_OK; }
    die("unmodelled rd_kafka_conf_set");
}

rd_kafka_t *rd_kafka_new(rd_kafka_type_t type, rd_kafka_conf_t *conf, char *, size_t) {
    rd_kafka_t *rk = new rd_kafka_s();
    rk->type = type;
    rk->conf = conf;
    g_rk_live++;
    return rk;
}
void rd_kafka_destroy(rd_kafka_t *rk) {
    if(!rk->queued.empty()) die("rd_kafka_destroy with undelivered messages");
    rd_kafka_conf_destroy(rk->conf);
    for(rd_kafka_message_t *m : g_destroyed) free_message(m);
    g_destroyed.clear();
    delete rk;
    g_rk_live--;
}
int rd_kafka_brokers_add(rd_kafka_t *, const char *list) { g_brokers = list; return 1; }
rd_kafka_resp_err_t rd_kafka_last_error(void) { return RD_KAFKA_RESP_ERR_NO_ERROR; }
const char *rd_kafka_version_str(void) { return "0.11.1-stub"; }
int rd_kafka_wait_destroyed(int) { return 0; }

rd_kafka_topic_conf_t *rd_kafka_topic_conf_new(void) {
    g_topic_conf_live++;
    return (rd_kafka_topic_conf_t *)calloc(1, sizeof(rd_kafka_topic_conf_t));
}
void rd_kafka_topic_conf_destroy(rd_kafka_topic_conf_t *c) { if(c) { g_topic_conf_live--; free(c); } }

rd_kafka_topic_t *rd_kafka_topic_new(rd_kafka_t *rk, const char *topic, rd_kafka_topic_conf_t *conf) {
    rd_kafka_topic_conf_destroy(conf); /* owned on success */
    rd_kafka_topic_t *t = new rd_kafka_topic_s();
    t->rk = rk;
    t->name = topic;
    t->next = 0;
    g_topic_live++;
    return t;
}
void rd_kafka_topic_destroy(rd_kafka_topic_t *t) { delete t; g_topic_live--; }
const char *rd_kafka_topic_name(const rd_kafka_topic_t *t) { return t->name.c_str(); }

int rd_kafka_consume_start(rd_kafka_topic_t *t, int32_t, int64_t) { t->next = 0; return 0; }
int rd_kafka_consume_stop(rd_kafka_topic_t *, int32_t) { return 0; }
rd_kafka_message_t *rd_kafka_consume(rd_kafka_topic_t *t, int32_t, int) {
    if(t->next++ == 0) return new_message(t, RD_KAFKA_RESP_ERR_NO_ERROR, 7, "hello", 5, "k", 1);
    return new_message(t, RD_KAFKA_RESP_ERR__PARTITION_EOF, 8, 0, 0, 0, 0);
}
void rd_kafka_message_destroy(rd_kafka_message_t *m) { g_destroyed.push_back(m); }
int64_t rd_kafka_message_timestamp(const rd_kafka_message_t *, rd_kafka_timestamp_type_t *tstype) {
    *tstype = RD_KAFKA_TIMESTAMP_CREATE_TIME;
    return 1234;
}

int rd_kafka_produce(rd_kafka_topic_t *t, int32_t partition, int msgflags, void *payload, size_t len,
                     const void *key, size_t keylen, void *msg_opaque) {
    if(msgflags != RD_KAFKA_MSG_F_COPY) die("produce without RD_KAFKA_MSG_F_COPY");
    rd_kafka_message_t *m = new_message(t, RD_KAFKA_RESP_ERR_NO_ERROR, 42, payload, len, key, keylen);
    m->partition = partition;
    m->_private = msg_opaque;
    t->rk->queued.push_back(m);
    return 0;
}
int rd_kafka_poll(rd_kafka_t *rk, int) {
    int n = (int)rk->queued.size();
    for(rd_kafka_message_t *m : rk->queued) {
        if(rk->conf->dr_msg_cb) rk->conf->dr_msg_cb(rk, m, rk->conf->opaque);
        free_message(m);
    }
    rk->queued.clear();
    return n;
}
rd_kafka_resp_err_t rd_kafka_flush(rd_kafka_t *rk, int ms) { rd_kafka_poll(rk, ms); return RD_KAFKA_RESP_ERR_NO_ERROR; }
int rd_kafka_outq_len(rd_kafka_t *rk) { return (int)rk->queued.size(); }

rd_kafka_resp_err_t rd_kafka_metadata(rd_kafka_t *, int, rd_kafka_topic_t *only, const struct rd_kafka_metadata **out, int) {
    rd_kafka_metadata_t *md = (rd_kafka_metadata_t *)calloc(1, sizeof *md);
    md->broker_cnt = 1;
    md->brokers = (rd_kafka_metadata_broker *)calloc(1, sizeof *md->brokers);
    md->brokers[0].id = 1;
    md->brokers[0].host = dup_bytes("broker.invalid", 14);
    md->brokers[0].port = 9092;
    md->topic_cnt = 1;
    md->topics = (rd_kafka_metadata_topic *)calloc(1, sizeof *md->topics);
    const char *name = only ? only->name.c_str() : "t";
    md->topics[0].topic = dup_bytes(name, strlen(name));
    md->topics[0].partition_cnt = 1;
    md->topics[0].partitions = (rd_kafka_metadata_partition *)calloc(1, sizeof *md->topics[0].partitions);
    md->topics[0].partitions[0].leader = 1;
    md->orig_broker_id = 1;
    md->orig_broker_name = dup_bytes("broker.invalid:9092/1", 21);
    g_metadata_live++;
    *out = md;
    return RD_KAFKA_RESP_ERR_NO_ERROR;
}
void rd_kafka_metadata_destroy(const struct rd_kafka_metadata *cmd) {
    rd_kafka_metadata_t *md = (rd_kafka_metadata_t *)cmd;
    free(md->brokers[0].host);
    free(md->brokers);
    free(md->topics[0].topic);
    free(md->topics[0].partitions);
    free(md->topics);
    free(md->orig_broker_name);
    free(md);
    g_metadata_live--;
}

rd_kafka_resp_err_t rd_kafka_list_groups(rd_kafka_t *, const char *group, const struct rd_kafka_group_list **out, int) {
    if(group) die("list_groups with a group filter");
    rd_kafka_group_list *gl = (rd_kafka_group_list *)calloc(1, sizeof *gl);
    gl->group_cnt = 1;
    gl->groups = (rd_kafka_group_info *)calloc(1, sizeof *gl->groups);
    rd_kafka_group_info &g = gl->groups[0];
    g.broker.id = 1;
    g.broker.host = dup_bytes("broker.invalid", 14);
    g.broker.port = 9092;
    g.group = dup_bytes("g", 1);
    g.state = dup_bytes("Stable", 6);
    g.protocol_type = dup_bytes("consumer", 8);
    g.protocol = dup_bytes("range", 5);
    g.member_cnt = 1;
    g.members = (rd_kafka_group_member_info *)calloc(1, sizeof *g.members);
    g.members[0].member_id = dup_bytes("m", 1);
    g.members[0].client_id = dup_bytes("c", 1);
    g.members[0].client_host = dup_bytes("/127.0.0.1", 10);
    g_grplist_live++;
    *out = gl;
    return RD_KAFKA_RESP_ERR_NO_ERROR;
}
void rd_kafka_group_list_destroy(const struct rd_kafka_group_list *cgl) {
    rd_kafka_group_list *gl = (rd_kafka_group_list *)cgl;
    rd_kafka_group_info &g = gl->groups[0];
    free(g.broker.host); free(g.group); free(g.state); free(g.protocol_type); free(g.protocol);
    free(g.members[0].member_id); free(g.members[0].client_id); free(g.members[0].client_host);
    free(g.members);
    free(gl->groups);
    free(gl);
    g_grplist_live--;
}

/* Linked by 4DPlugin.cpp but not reached by the controls. */
rd_kafka_conf_res_t rd_kafka_topic_conf_set(rd_kafka_topic_conf_t *, const char *, const char *, char *, size_t) { die("rd_kafka_topic_conf_set"); }
void rd_kafka_conf_set_rebalance_cb(rd_kafka_conf_t *, void (*)(rd_kafka_t *, rd_kafka_resp_err_t, rd_kafka_topic_partition_list_t *, void *)) { die("rd_kafka_conf_set_rebalance_cb"); }
void rd_kafka_conf_set_default_topic_conf(rd_kafka_conf_t *, rd_kafka_topic_conf_t *) { die("rd_kafka_conf_set_default_topic_conf"); }
rd_kafka_resp_err_t rd_kafka_assign(rd_kafka_t *, const rd_kafka_topic_partition_list_t *) { die("rd_kafka_assign"); }
rd_kafka_message_t *rd_kafka_consumer_poll(rd_kafka_t *, int) { die("rd_kafka_consumer_poll"); }
rd_kafka_resp_err_t rd_kafka_poll_set_consumer(rd_kafka_t *) { die("rd_kafka_poll_set_consumer"); }
rd_kafka_resp_err_t rd_kafka_subscribe(rd_kafka_t *, const rd_kafka_topic_partition_list_t *) { die("rd_kafka_subscribe"); }
rd_kafka_topic_partition_list_t *rd_kafka_topic_partition_list_new(int) { die("rd_kafka_topic_partition_list_new"); }
rd_kafka_topic_partition_t *rd_kafka_topic_partition_list_add(rd_kafka_topic_partition_list_t *, const char *, int32_t) { die("rd_kafka_topic_partition_list_add"); }
rd_kafka_resp_err_t rd_kafka_query_watermark_offsets(rd_kafka_t *, const char *, int32_t, int64_t *, int64_t *, int) { die("rd_kafka_query_watermark_offsets"); }

} // extern "C"
