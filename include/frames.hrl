-ifndef(frames_hrl).
-define(frames_hrl, true).

%% sub-records

-record(will, { topic = undefined :: binary(),
                message = undefined :: binary(),
                qos = 'at_least_once' :: qos_level(),
                retain = false :: boolean() }).

-record(subscription, { topic = undefined :: binary(),
                        qos = 'at_least_once' :: qos_level() }).

-record(qos, { level = 'at_most_once' :: 'at_most_once'
                                       | 'exactly_once',
               message_id = undefined :: message_id() }).

%% frames

-record(connect, { clean_session = undefined :: boolean(),
                   will = undefined :: #will{} | 'undefined',
                   username = undefined :: binary() | 'undefined',
                   password = undefined :: binary() | 'undefined',
                   client_id = undefined :: client_id(),
                   keep_alive = undefined :: 0..16#ffff }).

-record(connack, {
          return_code = ok :: return_code() }).

-record(publish, { dup = undefined :: boolean(),
                   retain = undefined :: boolean(),
                   qos = 'at_least_once' :: 'at_least_once'
                                          | #qos{},
                   topic = undefined :: binary(),
                   payload = undefined :: binary() }).

-record(puback, {
          message_id = undefined :: message_id() }).

-record(pubrec, {
          message_id = undefined :: message_id() }).

-record(pubrel, {
          dup = undefined :: boolean(),
          message_id = undefined :: message_id() }).

-record(pubcomp, {
          message_id = undefined :: message_id() }).

-record(subscribe, {
          dup = undefined :: boolean(),
          message_id = undefined :: message_id(),
          subscriptions = undefined :: subscriptions() }).

-record(suback, {
          message_id = undefined :: message_id(),
          qoses = undefined :: [qos_level()] }).

-record(unsubscribe, {
          message_id = undefined :: message_id(),
          topics = [] :: [binary()] }).

-record(unsuback, {
          message_id = undefined :: message_id() }).

%% pingreq, pingresp and disconnect have no fields, so are represented
%% by atoms

-endif.
