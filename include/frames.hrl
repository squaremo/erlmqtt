-ifndef(frames_hrl).
-define(frames_hrl, true).

%% sub-records

-record(will, { topic = undefined :: topic(),
                message = undefined :: payload(),
                qos = 'at_most_once' :: qos_level(),
                retain = false :: boolean() }).

-record(subscription, { topic = undefined :: topic(),
                        qos = 'at_most_once' :: qos_level() }).

-record(qos, { level = 'at_least_once' :: 'at_least_once'
                                       | 'exactly_once',
               message_id = undefined :: message_id() }).

%% frames

-record(connect, { clean_session = true :: boolean(),
                   will = undefined :: #will{} | 'undefined',
                   username = undefined :: binary() | 'undefined',
                   password = undefined :: binary() | 'undefined',
                   client_id = undefined :: client_id(),
                   keep_alive = 0 :: 0..16#ffff }).

-record(connack, {
          return_code = ok :: return_code() }).

-record(publish, { dup = false :: boolean(),
                   retain = false :: boolean(),
                   qos = 'at_most_once' :: 'at_most_once'
                                          | #qos{},
                   topic = undefined :: topic(),
                   payload = undefined :: payload() }).

-record(puback, {
          message_id = undefined :: message_id() }).

-record(pubrec, {
          message_id = undefined :: message_id() }).

-record(pubrel, {
          dup = false :: boolean(),
          message_id = undefined :: message_id() }).

-record(pubcomp, {
          message_id = undefined :: message_id() }).

-record(subscribe, {
          dup = false :: boolean(),
          message_id = undefined :: 'undefined' | message_id(),
          subscriptions = undefined :: [#subscription{}] }).

-record(suback, {
          message_id = undefined :: message_id(),
          qoses = undefined :: [qos_level()] }).

-record(unsubscribe, {
          message_id = undefined :: 'undefined' | message_id(),
          topics = [] :: [topic()] }).

-record(unsuback, {
          message_id = undefined :: message_id() }).

%% pingreq, pingresp and disconnect have no fields, so are represented
%% by atoms

-endif.
