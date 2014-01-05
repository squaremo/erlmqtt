
-record(fixed, { dup = undefined :: boolean(),
                 qos = undefined :: mqtt_framing:qos(),
                 retain = undefined :: boolean() }).

-record(will, { topic = undefined :: binary(),
                message = undefined :: binary(),
                qos = undefined :: mqtt_framing:qos(),
                retain = undefined :: boolean() }).

-record(connect, { fixed = undefined :: #fixed{},
                   clean_session = undefined :: boolean(),
                   will = undefined :: #will{}
                                     | 'undefined',
                   username = undefined :: binary() | 'undefined',
                   password = undefined :: binary() | 'undefined',
                   client_id = undefined :: mqtt_framing:client_id(),
                   keep_alive = undefined :: 0..16#ffff }).

-record(connack, { fixed = undefined :: #fixed{},
                   return_code = ok :: mqtt_framing:return_code() }).

-record(publish, { fixed = undefined :: #fixed{},
                   topic = undefined :: binary(),
                   message_id = undefined :: mqtt_framing:message_id(),
                   payload = undefined :: binary() }).

-record(puback, { fixed = undefined :: #fixed{},
                  message_id = undefined :: mqtt_framing:message_id() }).

-record(pubrec, { fixed = undefined :: #fixed{},
                  message_id = undefined :: mqtt_framing:message_id() }).

-record(pubrel, { fixed = undefined :: #fixed{},
                  message_id = undefined :: mqtt_framing:message_id() }).

-record(pubcomp, { fixed = undefined :: #fixed{},
                   message_id = undefined :: mqtt_framing:message_id() }).
