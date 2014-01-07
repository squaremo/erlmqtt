
%% sub-records

-record(will, { topic = undefined :: binary(),
                message = undefined :: binary(),
                qos = undefined :: mqtt_framing:qos(),
                retain = undefined :: boolean() }).

-record(subscription, { topic = undefined :: binary(),
                        qos = undefined :: mqtt_framing:qos() }).

%% frames

-record(connect, { clean_session = undefined :: boolean(),
                   will = undefined :: #will{}
                                     | 'undefined',
                   username = undefined :: binary() | 'undefined',
                   password = undefined :: binary() | 'undefined',
                   client_id = undefined :: mqtt_framing:client_id(),
                   keep_alive = undefined :: 0..16#ffff }).

-record(connack, { return_code = ok :: mqtt_framing:return_code() }).

-record(publish, { dup = undefined :: boolean(),
                   retain = undefined :: boolean(),
                   qos = undefined :: mqtt_framing:qos(),
                   topic = undefined :: binary(),
                   message_id = undefined :: mqtt_framing:message_id(),
                   payload = undefined :: binary() }).

-record(puback, {
          message_id = undefined :: mqtt_framing:message_id() }).

-record(pubrec, {
          message_id = undefined :: mqtt_framing:message_id() }).

-record(pubrel, {
          dup = undefined :: boolean(),
          qos = undefined :: mqtt_framing:qos(),
          message_id = undefined :: mqtt_framing:message_id() }).

-record(pubcomp, {
          message_id = undefined :: mqtt_framing:message_id() }).

-record(subscribe, {
          dup = undefined :: boolean(),
          qos = undefined :: mqtt_framing:qos(),
          message_id = undefined :: mqtt_framing:message_id(),
          subscriptions = undefined :: mqtt_framing:subscriptions() }).

-record(suback, {
          message_id = undefined :: mqtt_framing:message_id(),
          qoses = undefined :: [mqtt_framing:qos()] }).

-record(unsubscribe, {
          message_id = undefined :: mqtt_framing:message_id(),
          qos = undefined :: mqtt_framing:qos(),
          topics = undefined :: [binary()] }).

-record(unsuback, {
          message_id = undefined :: mqtt_framing:message_id() }).

%% pingreq, pingresp and disconnect have no fields, so are represented
%% by atoms
