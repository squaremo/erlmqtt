erlmqtt
=======

An Erlang client library for MQTT 3.1.

### Building

    $ make

### Testing

    $ make test && make dialyse

### Trying out

(Assuming RabbitMQ or another MQTT broker is running on localhost:1883)

    $ erl -pa ebin

    1> {ok, C} = mqtt_connection:start_link().
    2> mqtt_connection:connect(C, "localhost", "client1").
    3> mqtt_connection:publish(C, "topic/a/b", <<"payload">>).
