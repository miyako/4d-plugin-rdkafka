# 4d-plugin-rdkafka
4D implementation of [librdkafka](https://github.com/edenhill/librdkafka), the Apache Kafka client library

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

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

* Producer (based on the ``rdkafka_simple_producer.c`` example)

```
error:=KAFKA Produce (brokers;topic;payload;json)
```

Parameter|Type|Description
------------|------------|----
brokers|ARRAY TEXT|
topic|TEXT|
payload|BLOB|
json|TEXT|delivery report (``JSON``)
error|LONGINT|

