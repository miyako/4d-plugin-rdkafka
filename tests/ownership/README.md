# Ownership regressions

`engine_harness.mm` links the real `4DPlugin.cpp`, the plugin classes (`4D Plugin API/Classes/*.cpp`) and the unchanged bundled `4D Plugin API` with ASan/UBSan, and replaces the 4D engine (`Call4D`) with a synthetic one. That engine counts live engine strings, handles and reference-counted pictures, and aborts on anything it does not model.

librdkafka and libjson are replaced at their C API boundaries:
- `rdkafka_stub.cpp` is a synthetic, network-free librdkafka that serves one message, delivery reports, metadata and group lists, and counts live handles.
- `libjson_stub.cpp` is a counted model of the libjson C API the plugin uses. The vendored `a/libjson.a` targets the legacy GNU libstdc++ ABI and cannot be linked by current toolchains.

No broker is contacted: the stubs only record the `*.invalid` broker list.

The vendored headers and libraries are x86_64/i386, so the harness is built for x86_64 (Rosetta on Apple silicon).

```sh
tests/ownership/run.sh . fixed                # every test must pass

B=$(mktemp -d); git archive <base-sha> | tar -x -C "$B"
tests/ownership/run.sh "$B" baseline          # named defects must fail, controls pass
```

| Test | Checks |
|---|---|
| `defect_picture_fromfile_ownership` | `C_PICTURE::fromFileAtPath` frees the path once and releases the loaded picture |
| `defect_picture_setbytes_leak` | `C_PICTURE::setBytes` releases the picture it creates |
| `defect_picture_createcopy_ownership` | `createCopy*` reads only the converted type and leaves no empty owners |
| `defect_picture_grayscale_owner_leak`, `defect_picture_getsize_owner_leak`, `defect_picture_thumbnail_owner_leak` | no empty picture owner leaks |
| `control_kafka_*` | `KAFKA Consume` (count and until-EOF), `KAFKA Produce`, `Get version`, `Get topics`, `Get groups` through `PluginMain`: borrowed text array/BLOB parameters, text outputs and results, balanced engine, librdkafka and libjson state |
| `control_close_process`, `control_array_text_transfer`, `control_picture_param_return` | `PA_GetProcessInfo` on close, `ARRAY_TEXT` transfer, picture parameter/return |

`C_PICTURE` is compiled into the plugin, but no KAFKA command calls it.

Known issues outside 4D ownership. These are worked around or pinned, not fixed:
- `rd_kafka_message_destroy(rkmessage)` is followed by reads of `rkmessage->err` (the static-partition loop in `KAFKA_Consume` and in `__()`). The stub defers message frees to `rd_kafka_destroy`.
- Message keys are passed to `json_set_s` as C strings, but librdkafka keys are not NUL-terminated. The stub appends a NUL.
- `json_group_list()` leaks an unused `json_item_groups` node. `control_kafka_get_groups` pins exactly one leaked node.

Not covered:
- Windows and a real 4D runtime.
- Real librdkafka/libjson behaviour, and the balanced-consumer (`group`) path.
- How the real engine treats the old value of a picture output parameter. The harness assumes the most forgiving model: the engine releases it.
