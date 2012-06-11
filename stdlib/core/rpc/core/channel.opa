/*
    Copyright © 2011, 2012 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA.  If not, see <http://www.gnu.org/licenses/>.
*/

type GenChannel.how_send('message, 'serialized) =
  { serialize : 'message -> 'serialized; message : 'message } /
  /** Basic send */

  { serialize : 'message -> 'serialized; message : 'message;
    herror : -> void; hsuccess : -> void}
  /** Send with an error handler and success handler */

#<Ifstatic:OPA_CHANNEL>

/**
 * {3 Generic channels}
 */

@private type Actor.t('ctx, 'msg) = external

@private type GenChannel.local('ctx, 'msg, 'ser) =
  {local : Actor.t('ctx, 'msg) more:option(black) unserialize:'ser -> option('msg) id:string}
/**
 * A generic type of channel.
 */
@abstract type GenChannel.t('ctx, 'msg, 'ser, 'cid) =
  GenChannel.local('ctx, 'msg, 'ser)
/ {entity : 'cid}

/**
 * Type used for identify a channel
 */
type GenChannel.identity('cid) =
  {entity_id : 'cid}
/ {local_id : string}

/**
 * A type module used for communicates between several ['entity] of the defined
 * network.
 */
type GenChannel.NETWORK('cid, 'entity, 'serialized) = {{

  /**
   * Should be allows to send a serialized message to a channel identified by
   * cid owned by entity.
   */
  send : 'entity, 'cid, 'serialized -> void

  /**
   * Should be allows to send a serialized message with a report.
   */
  try_send : 'entity, 'cid, 'serialized -> bool

  default_entity : option('entity)

  hash_cid : 'cid -> string

  equals_cid : 'cid, 'cid -> bool

}}

/**
 * A Generic module which defines a channel networks
 */
GenChannel(N:GenChannel.NETWORK('cid, 'entity, 'ser)) = {{

  /**
   * {3 Private Utils}
   */
  /**
   * Generate a local identifier.
   */
  @private genid = String.fresh(0)

  @private error(msg) =
    Log.error("CHANNEL", msg)

  @private debug(msg) =
    Log.debug("CHANNEL", msg)

  @private
  how_to_report(how:GenChannel.how_send) =
    match how with
    | ~{herror hsuccess ...} -> {
        error = (msg -> do error(msg) Scheduler.push(herror))
        success = -> Scheduler.push(hsuccess)
        should = true
      }
    | _ -> {~error success=-> void should=false}

  @private
  how_to_message(how:GenChannel.how_send) =
    match how with
    | {~message serialize=_} -> message
    | {~message ...} -> message

  @private
  how_to_serialized(how:GenChannel.how_send) =
    match how with
    | {~message ~serialize}
    | {~message ~serialize ...} -> serialize(message)

  @private entity_channels : Hashtbl.t('cid, 'entity) =
    Hashtbl.make(N.hash_cid, N.equals_cid, 1024)

  @private local_infos : Hashtbl.t(string, {id : string cb : -> void}) =
    Hashtbl.create(1024)

  @private local_channels : Hashtbl.t(string, GenChannel.local) =
    Hashtbl.create(1024)

  make(
    state:'state,
    handler:Session.handler('state, 'msg),
    unserialize:'ser -> option('msg),
    selector:Session.context_selector,
    more:option('a)
    ) : GenChannel.t('ctx, 'msg, 'ser, 'cid) =
    llmake(state, _, handler, ondelete, ctx, more, concurrent) =
      local = @may_cps(%%BslActor.make%%)(state, handler, ondelete, ctx, concurrent)
      more=Option.map(Magic.black, more)
      ~{local more unserialize id=genid()}
    Session_private.make_make(state, unserialize, handler, more, selector, llmake)

  @private post(ctx:option('ctx), msg:'msg, actor : Actor.t('ctx, 'msg)) =
    %%BslActor.post%%(ctx, msg, actor)

  send_to_entity(cid, msg, report) =
    match
      match @atomic(Hashtbl.try_find(entity_channels, cid)) with
      | {none} -> N.default_entity
      | x -> x
    with
    | {none} ->
      report.error("Entity channel({cid}) not found: Can't send the message")
    | {some = entity} ->
      if report.should then
        if N.try_send(entity, cid, msg) then report.success()
        else report.error("Entity channel({cid}) can't be reached")
      else N.send(entity, cid, msg)

  /**
   * Send a message along a channel
   */
  send(ctx:option('ctx),
       channel:GenChannel.t('ctx, 'msg, 'ser, 'cid),
       how:GenChannel.how_send('msg, 'ser)) =
    report = how_to_report(how)
    match channel with
    | ~{local  unserialize id ...} ->
      do post(ctx, how_to_message(how), local)
      report.success()
    | {entity = cid} -> send_to_entity(cid, how_to_serialized(how), report)


  /**
   * Forward a message along a channel
   */
  forward(ctx : option('ctx),
          channel : GenChannel.t('ctx, 'msg, 'ser, 'cid),
          msg:'ser,
          how:GenChannel.how_send('msg, 'ser)) =
    match channel with
    | ~{local  unserialize id ...} ->
      match unserialize(msg) with
      | {none} -> error("Error on message unserialization for the local channel({id})")
      | {some = msg} -> post(ctx, msg, local)
      end
    | {entity = cid} -> send_to_entity(cid, msg, how_to_report(how))

  remove(ident : GenChannel.identity('cid)) =
    match ident with
    | {local_id = id} ->
      cb = @atomic(
        match Hashtbl.try_find(local_infos, id) with
        | {none} -> (-> void)
        | {some = {~cb ...}} ->
          do Hashtbl.remove(local_infos, id)
          cb
        )
      Scheduler.push(cb)
    | {entity_id = cid} ->
      Hashtbl.remove(entity_channels, cid)

  register(cid : 'cid, entity : 'entity) =
    @atomic(Hashtbl.add(entity_channels, cid, entity))

  find(ident : GenChannel.identity('cid)) : option(channel('a)) =
    match ident with
    | {local_id = id} ->
      match Hashtbl.try_find(local_channels, id) with
      | {none} as x ->
        do error("Local channel({id}) not found") x
      | x -> x <: option(GenChannel.t)
      end
    | {entity_id = id} ->
      match Hashtbl.try_find(entity_channels, id) with
      | {none} ->
        do error("Entity channel({id}) not found")
        {none}
      | _ -> {some = {entity = id}}

  owner(c:GenChannel.t('ctx, 'msg, 'ser, 'cid)):option('entity) =
    match c with
    | {entity = id} -> Hashtbl.try_find(entity_channels, id)
    | {local=_ ...} -> none

  identify(c:GenChannel.t):GenChannel.identity =
    match c with
    | {local=_ ~id ...} as c ->
      @atomic(
        match Hashtbl.try_find(local_infos, id) with
        | {some = {~id ...}} -> {local_id = id}
        | {none} ->
          x = Random.string(20) ^ id
          #<Ifstatic:MLSTATE_SESSION_DEBUG>
          do debug("Instantiate channel("^id^") as "^x^"")
          #<End>
          do Hashtbl.add(local_channels, x, c)
          do Hashtbl.add(local_infos, id, {id = x; cb = -> void})
          {local_id = x}
      )
    | {entity = cid} -> {entity_id = cid}


}}

/**
 * {3 Opa Network}
 */
type OpaNetwork.cid = {other : string} / {remote /*TODO*/}

type OpaNetwork.entity =
  {server}
/ {client : ThreadContext.client}
/ {remote peer /*TODO*/}
/ {remote client /*TODO*/}

type OpaNetwork.msg = RPC.Json.json

/**
 * {3 Opa Channel}
 */
@private type Channel.t('msg) = GenChannel.t(ThreadContext.t, 'msg, RPC.Json.json, OpaNetwork.cid)

@private type Channel.identity = GenChannel.identity(OpaNetwork.cid)

@private type Channel.how_send('msg) = GenChannel.how_send('msg, RPC.Json.json)

@abstract type channel('msg) = Channel.t('msg)

@private @publish __send_(client, msg) =
  PingRegister.send(client, msg)

@private __unpublish_ = void  //TODO OpaRPC_Server.Dispatcher.unpublish(@rpckey(__send_))

@both_implem
Channel = {{

  @private error(msg) =
    Log.error("OPACHANNEL", msg)

  @private lfield = @sliced_expr({client="cl_id" server="srv_id"})

  @private ofield = @sliced_expr({client="srv_id" server="cl_id"})

  OpaNetwork : GenChannel.NETWORK(OpaNetwork.cid, OpaNetwork.entity, OpaNetwork.msg) = {{

    @private
    error(msg) = Log.error("OpaNetwork", msg)

    @private
    serialize_cid : OpaNetwork.cid -> RPC.Json.json=
      | ~{other} -> {Record = [(ofield, {String = other})]}
      | {remote} -> {String = "TODO/REMOTE"}

    send(entity:OpaNetwork.entity, cid:OpaNetwork.cid, message:OpaNetwork.msg) =
      @sliced_expr({
        client =
          to = serialize_cid(cid)
          msg = {Record = [("to", to), ("message", message:RPC.Json.json)]}
          PingClient.async_request("/chan/send", Json.to_string(msg))

        server =
          match entity with
          | {server} -> error("Send to the server entity should not happens")
          | ~{client} ->
            match cid with
            | {remote} -> error("Can't send a message to a remote session to a client")
            | ~{other} ->
              msg = {Record = [
                ("type", {String = "chan"}),
                ("id", serialize_cid(cid)),
                ("msg", message),
              ]}
            _ = __send_(client, msg)
            void
          | _ -> error("Send to {entity} is not yet implemented")

      })

    try_send(e:OpaNetwork.entity, c:OpaNetwork.cid, m:OpaNetwork.msg) =
      // TODO
      do send(e, c, m)
      true

    default_entity = @sliced_expr({client = some({server}) server=none})

    hash_cid = OpaValue.to_string : OpaNetwork.cid -> string

    equals_cid = `==` : OpaNetwork.cid, OpaNetwork.cid -> bool

  }}

  @private OpaChannel = GenChannel(OpaNetwork)

  remove = OpaChannel.remove

  find = OpaChannel.find

  make = OpaChannel.make

  register = OpaChannel.register

  identify = OpaChannel.identify

  send(chan : channel('msg), how : Session.how_send('msg)) =
    OpaChannel.send(ThreadContext.get_opt({current}), chan, how)

  forward = OpaChannel.forward

  serialize(channel, _o):RPC.Json.json =
    match OpaChannel.identify(channel) with
    | {local_id=id}          ->
      do @sliced_expr({server=void client=PingClient.register_actor(id)})
      {Record = [(lfield, {String=id})]}
    | {entity_id={other=id}} -> {Record = [(ofield, {String=id})]}
    | _ -> @fail

  unserialize(json:RPC.Json.json):option(channel) =
    match json with
    | {Record = [(jfield, {String = id})]} ->
      ident : option(Channel.identity) =
        if jfield == lfield then {some = {local_id = id}}
        else if jfield == ofield then
          do @sliced_expr({
            client=OpaChannel.register({other = id}, {server})
            server=void
          })
          {some = {entity_id = {other = id}}}
        else do error("Bad JSON fields : {jfield}") {none}
      Option.bind(OpaChannel.find, ident)
    | _ ->
      do error("Bad formatted JSON : {json}")
      {none}

  owner = OpaChannel.owner : channel -> option(OpaNetwork.entity)

  is_client(entity:OpaNetwork.entity) = match entity with
    | {client=_ ...} -> true
    | _ -> false

  is_local(c:channel) =
    match c with
    | {local=_ ...} -> true
    | _ -> false

  get_more(c:channel) =
    match c with
    | ~{more ...} -> Option.map(Magic.id, more)
    | _ -> none

  ordering(c0:channel('msg), c1:channel('msg)) =
    match (c0, c1) with
    | ({entity={other=id0}}, {entity={other=id1}})
    | ({local=_ id=id0 ...}, {local=_ id=id1 ...} ) -> String.ordering(id0, id1)
    | ({entity = {remote}}, {entity = {remote}}) -> {eq}
    | ({local=_ ...}, {entity=_}) -> {gt}
    | ({entity=_}, {local=_ ...}) -> {lt}

  order = @nonexpansive(Order.make(ordering))

  on_remove(channel, cb) = void

}}

ChannelServer = {{
  get_id(channel, _client_opt) =
    match Channel.identify(channel) with
    | ~{local_id} -> some(local_id)
    | _ -> none
}}
#<Else>
@abstract type channel('msg) = Session.private.channel('msg)

/**
 * A partial order on channels
 */
compare_channel(a:channel('msg), b:channel('msg)) : Order.ordering =
  Order.of_int(%%Session.compare_channels%%(a, b))

Channel = {{
  order = @nonexpansive(Order.make(compare_channel)) : order(channel('message), Channel.order)

  /**
   * Low level make channel
   *
   * Considering an original [state] a function for [unserialize]
   * remote message. An [handler] who treat received message with
   * the current state. You also can attach any [more] information
   * on the created session. [selector] is used for determine in
   * which context the [handler] is execute :
   * - { maker } -> [handler] is executed with the context of the
   *   session's creator.
   * - { sender } -> [handler] is executed with the context of the
   *   session's caller.
   *
   * Note : This features (selector) work only if the session is
   * created on the server. Use selector [{maker}] by default unless
   * if you are aware what you do.
   */
  make(
    state : 'st,
    handler : Session.handler('state, 'message),
    unserialize : RPC.Json.json -> option('msg),
    selector : Session.context_selector,
    more : 'more
    ) =
      make = @may_cps(%%Session.llmake%%)
      Session_private.make_make(state, unserialize, handler, more, selector, make)

  send = Session_private.llsend

  /**
   * {2 Utilities}
   */
  /**
   * Get the server [entity] corresponding to the given [endpoint].
   */
  @private get_server_entity = %%Session.get_server_entity%%

  /**
   * Returns entity which own the given channel
   */
  @private owner(chan : channel) =
    bsl = %%Session.owner%%
    bsl(chan)

  /**
   * Return true if the given entity is a client
   */
  @private is_client(entity) =
    bsl = %%Session.is_client%%
    bsl(entity)

  /**
   * Get the endpoint where the session is located, if [session] is
   * local return [none].
   */
  @private get_endpoint(chan : channel) =
    bsl = %%Session.get_endpoint%%
    bsl(chan)

  /**
   * Returns true if the channel is not owned by this server.
   * Beware, this returns false in case of non RemoteClient.
   */
  is_remote(chan : channel) =
    bsl = %%Session.is_remote%%
    bsl(chan)

  /**
   * Returns true only if the channel is owned by this server.
   * Returns false in case of Client.
  **/
  is_local = %%Session.is_local%% : channel -> bool

  /**
   * [on_remove_server] For internal use.
   */
  @private @server on_remove_server(chan:channel('msg), f:-> void): void =
    bp = @may_cps(%%Session.on_remove%%)
    : Session.private.native('a, _), (-> void) -> void
    bp(chan, f)

  /**
   * [on_remove_both] For internal use.
   */
  @private on_remove_both(chan:channel('msg), f:-> void): void =
    bp = @may_cps(%%Session.on_remove%%)
    : Session.private.native('a, _), (-> void) -> void
    bp(chan, f)

  /**
   * [on_remove channel f] Execute f when the [channel] is removed
   * of this server (no effect on the client).
   */
  on_remove(chan:channel('msg), f:-> void): void =
    if is_local(chan)
    then on_remove_both(chan, f)
    else on_remove_server(chan, f)

  /**
   * {2 Utilities}
   */

  /**
   * Serialize / Unserialize channel functions
   */

  serialize(x:channel('msg), options:OpaSerialize.options) : RPC.Json.json =
    x = match options.to_session with
    | {none} ->
      aux = @may_cps(%%Session.export%%)
      ctx = match ThreadContext.get({current}).key with
        | {server = _} | {nothing} ->
          // This case is on toplelvel javascript serialization.
          // Use a client identity which can't be collected.
          ThreadContext.Client.fake
        | ~{client} -> client
      aux(x, ctx)
    | {some = entity} ->
      aux = @may_cps(%%Session.serialize_for_entity%%)
      aux(x, entity)
    Option.get_msg(-> "[Session.serialize] Json object malformed",
                   Json.from_ll_json(x))



  unserialize(x : RPC.Json.json) : option(channel('msg)) =
    aux = @may_cps(%%Session.unserialize%%)
            : option(ThreadContext.t), RPC.Json.private.native -> option(Session.private.native('msg, _))
    match aux(ThreadContext.get_opt({current}), Json.to_ll_json(x)) with
    | {none} -> do Log.error("[Session][unserialize]","fail") {none}
    | {some = r}-> {some = r}

  get_more = %% Session.get_more%%

}}

ChannelServer = {{
  get_id = %%Session.get_server_id%%
}}
#<End>
