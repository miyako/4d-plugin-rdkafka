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

* macOS static libraries are not committed: run ``scripts/build-macos-deps.sh``
  to build ``a/libcrypto.a``, ``a/libssl.a``, ``a/libz.a``, ``a/librdkafka.a``
  and ``a/libjson.a`` as universal arm64+x86_64 archives from pinned sources
  (OpenSSL 1.1.1w, zlib 1.3.1, librdkafka 0.11.1, libjson 7.6.1). Release CI
  builds and caches them automatically.

* Windows static libraries are not committed as build inputs: run
  ``scripts/build-windows-deps.ps1`` to rebuild ``lib\64`` (``libcrypto.lib``,
  ``libssl.lib``, ``libz.lib``, ``librdkafka.lib``, ``libjson.lib``) with the
  installed MSVC toolchain, from the same pinned sources as macOS (OpenSSL
  1.1.1w, zlib 1.3.1, librdkafka 0.11.1, libjson 7.6.1). Release CI builds and
  caches them automatically.
  The 2017-era v140 archives once committed in ``lib\64`` no longer link with
  the modern toolchain: their LTCG data comes from a different compiler
  generation and the plugin link fails with ``LNK C1047``. The rebuild uses
  the win32 vcxproj's own source list with ``LIBRDKAFKA_STATICLIB`` (the
  ``LIBRDKAFKA_EXPORTS`` define, needed for the DLL build, is not used) and
  compiles **without** ``/GL``, so the archives link into the plugin's
  ``/LTCG`` link from any MSVC generation. ``src/win32_config.h`` enables SSL,
  zlib, SASL-SCRAM, snappy and plugins, matching the original build; the
  vcxproj also links ``crypt32.lib``, and librdkafka pulls in ``ws2_32.lib``
  and ``Secur32.lib`` itself via ``#pragma comment(lib, ...)``.

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
json|TEXT|cluster metadata (``JSON`` array)
error|LONGINT|return value for ``rd_kafka_metadata()``

structure of the metadata object:

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
error:=KAFKA Produce (brokers;topic;payload;key;json;partition)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|
payload|BLOB|
key|TEXT|
json|TEXT|delivery reports (``JSON`` array)
partition|LONGINT|
error|LONGINT|

structure of each delivery report:

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

on failure a report contains only ``error : number``.

* Consumer (based on the ``rdkafka_consumer_example.c`` example)

```
error:=KAFKA Consume (brokers;topic;json;partition;group;offset;count)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|
json|TEXT|consumed messages (``JSON`` array)
partition|LONGINT|
group|TEXT|optional
offset|LONGINT|optional
count|LONGINT|optional; ``0`` or negative means unlimited
error|LONGINT|

structure of each message:

```
partition : number
offset : number
len : number
topic : string
key : string (optional)
key_len : number (optional)
create_time : string[int64] (optional)
append_time : string[int64] (optional)
value : string
data : string[base64]
```

if partition is ``RD_KAFKA_PARTITION_UA``, group must not be empty string.

if group is omitted, partition must not be ``RD_KAFKA_PARTITION_UA``.

if partition is not ``RD_KAFKA_PARTITION_UA``, offset can be relative to total.

```
error:=KAFKA Get groups (brokers;json)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
json|TEXT|groups (``JSON`` array)

structure of each group:

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

