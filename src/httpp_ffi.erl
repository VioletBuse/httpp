-module(http_stream_ffi)

-export([send/5, insert_selector_handler/2])

send(Method, Url, Headers, Body, Options) ->
    case hackney:request(Method, Url, Headers, Body, Options) of
        {ok, Status, ResponseHeaders, <<Binary>>} ->
            {ok, {binary_response, Status, ResponseHeaders, Binary}};

        {ok, Status, ResponseHeaders, ClientRef} ->
            {ok, {client_ref_response, Status, ResponseHeaders, ClientRef}};

        {ok, Status, ResponseHeaders} ->
            {ok, {response_without_body, Status, ResponseHeaders}};

        {ok, ClientRef} ->
            {ok, {solo_client_ref_response, ClientRef}};

        {error, {closed, PartialBody}} ->
            {error, connection_closed}

        {error, Error} ->
            {error, {other, Error}}
    end.

insert_selector_handler({selector, Handlers}, Tag, Fn) ->
    {selector, Handlers#{Tag => Fn}}.
