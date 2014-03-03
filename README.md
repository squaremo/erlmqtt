erlmqtt
=======

An Erlang client library for MQTT 3.1 (but not for MQTT 3.1.1, yet).

### Building

    $ make

### Testing

    $ make test && make dialyse

### Trying out

This API may change, especially with respect to receiving messages.

(Assuming RabbitMQ or another MQTT broker is running on localhost:1883)

    $ erl -pa ebin

*Opening a connection and subscribing*

```erlang
1> {ok, C} = erlmqtt:open_clean("localhost", []).
{ok,<0.35.0>}
2> {ok, _} = erlmqtt:subscribe(C, [{"topic/#", at_most_once}]).
{ok,[at_most_once]}
```

`open_clean` starts a fresh connection that doesn't keep state around
when disconnected. The second argument is a proplist of options, for
example, `[{keep_alive, 600}]`.

Also exported are `open/2` and `open/3`, which start connections with
persistent state (though resumption of those after disconnection is
not fully implemented yet).

*Publishing messages*

```erlang
3> erlmqtt:publish(C, "topic/a/b", <<"payload">>).
ok
```

There's also a `publish/4` which accepts a proplist of options, e.g.,
`[retain, at_least_once]`, and `publish_sync/4` and `publish_sync/5`,
which publish a message using guaranteed delivery and return when the
message has been delivered (or in the case of `publish_sync/5`, if it
has timed out).

```erlang
4> erlmqtt:publish_sync(C, "/dev/null", <<"payload">>, at_least_once).
ok
```

Currently, using "quality of service" (guaranteed delivery) other than
`at_most_once` does not get you a lot; the connection will enact the
correct protocol, but if it crashes you will still lose the state.

*Receiving messages*

```erlang
5> erlmqtt:recv_message(1000).
{<<"topic/a/b">>,<<"payload">>}
6> erlmqtt:recv_message(1000).
timeout
7> erlmqtt:publish(C, "topic/foo", <<"payload">>).
8> erlmqtt:poll_message().
{<<"topic/foo">>,<<"payload">>}
9> erlmqtt:poll_message().
none
```

When a connection is opened, the calling process is volunteered as the
message consumer. This means the connection will deliver messages to
its mailbox. `recv_message/0` and `recv_message/1` wait for a message
to arrive (in the latter case, for a limited time) and return it as a
pair of topic and payload. `poll_message/0` returns a pair of topic
and payload if a message is available in the mailbox now, otherwise
`'none'`.
