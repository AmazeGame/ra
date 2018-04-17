-module(consumer).

-behaviour(gen_server).

%% API functions
-export([start_link/1,
         wait/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("ra.hrl").

-type config() :: #{cluster_id := ra_cluster_id(),
                    nodes := [ra_node_id()],
                    consumer_tag := binary(),
                    num_messages := integer(),
                    notify => pid(),
                    prefetch := integer()
                    }.

-record(state, {state :: ra_fifo_client:state(),
                consumer_tag :: binary(),
                max :: integer(),
                notify :: undefined | pid(),
                num_received = 0 :: non_neg_integer()}).


%%%===================================================================
%%% API functions
%%%===================================================================

-spec start_link(config()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

wait(Pid, Timeout) ->
    gen_server:call(Pid, wait, Timeout).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([#{cluster_id := ClusterId,
        nodes := Nodes,
        num_messages := Max,
        prefetch := Pref,
        consumer_tag := ConsumerTag} = C]) ->
    F = ra_fifo_client:init(ClusterId, Nodes),
    {ok, F1} = ra_fifo_client:checkout(ConsumerTag, Pref, F),
    {ok, #state{state = F1, consumer_tag = ConsumerTag,
                notify = maps:get(notify, C, undefined),
                max = Max}}.

handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ra_event, From, Evt}, #state{state = F0,
                                          num_received = Recvd,
                                          notify = Not,
                                          max = Max} = State0) ->
    case ra_fifo_client:handle_ra_event(From, Evt, F0) of
        {internal, _Applied, F} ->
            % ?INFO("consumer applied ~w~n", [Applied]),
            {noreply, State0#state{state = F}};
        {{delivery, _, Dels}, F1} ->
            MsgIds = [X || {X, _} <- Dels],
            {ok, F} = ra_fifo_client:settle(State0#state.consumer_tag,
                                            MsgIds, F1),
            case State0#state{state = F,
                              num_received = Recvd + length(MsgIds)} of
                #state{num_received = Max} = State ->
                    ?INFO("Consumer: received ~b~n", [Max]),
                    case Not of
                        undefined -> ok;
                        Pid ->
                            Pid ! consumer_done
                    end,
                    {noreply, State};
                State ->
                    {noreply, State}
            end
    end;
handle_info(_, State0) ->
    {noreply, State0}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================