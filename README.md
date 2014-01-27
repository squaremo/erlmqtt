erlmqtt
=======

An Erlang client library for MQTT 3.1 (but not for MQTT 3.1.1, yet).

### Building

    $ make

### Testing

    $ make test && make dialyse

### Trying out

(Assuming RabbitMQ or another MQTT broker is running on localhost:1883)

    $ erl -pa ebin

*Subscribing*

    1> {ok, C} = mqtt_connection:start_link("localhost", "client1").
    2> ok = mqtt_connection:connect(C).
    3> {ok, Ref} = mqtt_connection:subscribe(C, [{"topic/#", at_most_once}]).
    4> receive {Ref, Reply} -> Reply after 1000 -> timeout end.

*Publishing*

    5> mqtt_connection:publish(C, "topic/a/b", <<"payload">>).

*Receiving messages*

    6> receive {frame, Msg} -> Msg after 5000 -> timeout end.

This API is likely to change, especially with respect to receiving
messages.
