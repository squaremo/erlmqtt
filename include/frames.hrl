
-record(fixed, { type = undefined,
                 dup = undefined,
                 qos = undefined,
                 retain = undefined }).

-record(connect, { fixed = undefined,
                   clean_session = undefined,
                   will_topic = undefined,
                   will_msg = undefined,
                   will_qos = undefined,
                   will_retain = undefined,
                   username = undefined,
                   password = undefined,
                   client_id = undefined,
                   keep_alive = undefined }).
