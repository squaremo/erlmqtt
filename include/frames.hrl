
-record(fixed, { type = undefined :: mqtt_framing:message_type(),
                 dup = undefined :: boolean(),
                 qos = undefined :: mqtt_framing:qos(),
                 retain = undefined :: boolean() }).

-record(connect, { fixed = undefined :: #fixed{},
                   clean_session = undefined :: boolean(),
                   will_topic = undefined :: binary() | 'undefined',
                   will_msg = undefined :: binary() | 'undefined',
                   will_qos = undefined :: mqtt_framing:qos(),
                   will_retain = undefined :: boolean(),
                   username = undefined :: binary() | 'undefined',
                   password = undefined :: binary() | 'undefined',
                   client_id = undefined :: binary(),
                   keep_alive = undefined :: 0..16#ffff }).

-record(connack, { fixed = undefined :: #fixed{},
                   return_code = ok :: mqtt_framing:return_code() }).

-record(publish, { fixed = undefined :: #fixed{},
                   topic = undefined :: binary(),
                   message_id :: 1..16#ffff,
                   payload :: binary() }).
