-module(httpp_ffi).

-export([send/5, insert_selector_handler/3]).

send(Method, Url, Headers, Body, Options) ->
    case hackney:request(Method, Url, Headers, Body, Options) of
        {ok, Status, ResponseHeaders, <<Binary>>} ->
            {ok, {binary_response, Status, ResponseHeaders, Binary}};

        {ok, Status, ResponseHeaders, ClientRef} ->
            {ok, {client_ref_response, Status, ResponseHeaders, ClientRef}};

        {ok, Status, ResponseHeaders} ->
            {ok, {empty_response, Status, ResponseHeaders}};

        {ok, ClientRef} ->
            {ok, {async_response, ClientRef}};

        {error, {closed, PartialBody}} ->
            {error, {connection_closed, PartialBody}};

        {error, Error} ->
            {error, {other, Error}}
    end.

close(ClientRef) ->
  hackney:close(ClientRef),
  nil.

insert_selector_handler({selector, Handlers}, Tag, Fn) ->
    {selector, Handlers#{Tag => Fn}}.
