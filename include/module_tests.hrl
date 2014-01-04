%% Tests that are the same in each module

%% Check the spec for any exported functions
specs_test() ->
    ?assertEqual([], proper:check_specs(?MODULE)).

%% Check any properties defined in the module
proper_module_test() ->
    ?assertEqual([], proper:module(?MODULE, [long_result])).
