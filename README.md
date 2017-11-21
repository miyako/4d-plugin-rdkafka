# 4d-plugin-rdkafka
4D implementation of [librdkafka](https://github.com/edenhill/librdkafka), the Apache Kafka client library

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

## Releases

https://github.com/miyako/4d-plugin-rdkafka/releases/tag/0.1

## Build Information

* Static ``librdkafka`` for Windows

disable ``SAFESEH``, add ``legacy_stdio_definitions.lib``, add ``LIBRDKAFKA_STATICLIB``.

expand ``openssl`` macros.

```
# define CRYPTO_num_locks()            (1)
# define SSL_load_error_strings() \
OPENSSL_init_ssl(0x00200000L \
| 0x00000002L, NULL)
#define SSLv23_client_method    TLS_client_method
```

* Static ``libssl`` and ``libcrypto`` for Windows

https://github.com/David-Reguera-Garcia-Dreg/Precompiled-OpenSSL-Windows

add ``crypt32.lib``.

---

## Syntax

```
version:=KAFKA Get version
```

Parameter|Type|Description
------------|------------|----
version|TEXT|``0.11.1``

```
error:=KAFKA Get topics (brokers;topic;json)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|pass ``""`` to specify all topics  
json|TEXT|metadata (``JSON``)
error|LONGINT|return value for ``rd_kafka_metadata()``

structure of metadata:

```
topic : string | "*"
orig_broker_id : number
orig_broker_name : string
brokers[] 
  port : number
  id : number
  host : string
topics[]
  topic : string
  partitions[]
    id : number
    leader : number
```

* Producer (based on the ``rdkafka_simple_producer.c`` example)

```
error:=KAFKA Produce (brokers;topic;payload;json;partition)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|
payload|BLOB|
key|TEXT|
json|TEXT|delivery report (``JSON``)
partition|LONGINT|
error|LONGINT|

structure of delivery report:

```
len : number
partition : number
offset : number
topic : string
key : string (optional)
key_len : number (optional)
create_time : string[int64] (optional)
append_time : string[int64] (optional)
value : string
data : string[base64]
```

* Consumer (based on the ``rdkafka_consumer_example.c`` example)

```
error:=KAFKA Consume (brokers;topics;json)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|
json|TEXT|delivery report (``JSON``)
partition|LONGINT|
group|TEXT|optional
offset|LONGINT|optional
count|LONGINT|optional
error|LONGINT|

if partition is ``RD_KAFKA_PARTITION_UA``, group must not be empty string.

if group is omitted, partition must not be ``RD_KAFKA_PARTITION_UA``.

if partition is not ``RD_KAFKA_PARTITION_UA``, offset can be relative to total.

```
error:=KAFKA Get groups (brokers;json)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
json|TEXT|metadata (``JSON``)

structure of metadata:

```
group : string
state : string
broker_id : number
broker_port : number
broker_host : string
protocol_type : string
protocol : string
members[]
  member_id : string
  client_id : string
  client_host : string
  member_assignment_size : number
  member_metadata_size : number
```

